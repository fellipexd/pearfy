import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import PearfyContext
import PearfyWeb

private typealias ResponsePart = HTTPPart<HTTPResponseHead, ByteBuffer>
private typealias RequestChannel = NIOAsyncChannel<HTTPServerRequestPart, ResponsePart>
private typealias ListenerChannel = NIOAsyncChannel<RequestChannel, Never>

/// SwiftNIO-backed HTTP/1.1 listener. Routing is frozen before the socket opens.
public actor PearfyHTTPServer: ApplicationLifecycle {
    public nonisolated let name = "Pearfy HTTP listener"

    private let router: HTTPRouter
    private let host: String
    private let port: Int
    private let maximumBodyBytes: Int
    private let maximumHeaderBytes: Int

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var listener: ListenerChannel?
    private var serverTask: Task<Void, Never>?
    private var activeConnections: ActiveConnectionRegistry?

    public init(
        router: HTTPRouter,
        host: String = "127.0.0.1",
        port: Int = 8080,
        maximumBodyBytes: Int = 1_048_576,
        maximumHeaderBytes: Int = 65_536
    ) {
        self.router = router
        self.host = host
        self.port = port
        self.maximumBodyBytes = max(0, maximumBodyBytes)
        self.maximumHeaderBytes = max(0, maximumHeaderBytes)
    }

    public func waitForShutdown() async {
        await serverTask?.value
    }

    public func start() async throws {
        guard listener == nil else { return }
        try await router.freeze()

        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let activeConnections = ActiveConnectionRegistry()
        var decoderConfiguration = NIOHTTPDecoderLimitConfiguration()
        decoderConfiguration.maxHeaderFieldSize = min(maximumHeaderBytes, 80 * 1024)
        decoderConfiguration.maxHeaderListSize = min(maximumHeaderBytes, 80 * 1024)
        decoderConfiguration.maxHeaderFieldCount = 128
        let decoderLimits = decoderConfiguration
        let maximumBodyBytes = self.maximumBodyBytes

        do {
            let listener = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(host: host, port: port) { (channel: Channel) -> EventLoopFuture<RequestChannel> in
                    activeConnections.insert(channel)
                    channel.closeFuture.whenComplete { _ in activeConnections.remove(channel) }
                    return channel.pipeline.configureHTTPServerPipeline(
                        withDecoderLimitConfiguration: decoderLimits
                    ).flatMap {
                        channel.pipeline.addHandler(HTTPResponsePartBridge())
                    }.flatMap {
                        channel.eventLoop.makeCompletedFuture {
                            try RequestChannel(wrappingChannelSynchronously: channel)
                        }
                    }
                }

            self.eventLoopGroup = group
            self.listener = listener
            self.activeConnections = activeConnections
            let router = self.router
            let maximumHeaderBytes = self.maximumHeaderBytes
            self.serverTask = Task {
                await Self.serve(
                    listener: listener,
                    router: router,
                    maximumBodyBytes: maximumBodyBytes,
                    maximumHeaderBytes: maximumHeaderBytes
                )
            }
        } catch {
            try await group.shutdownGracefully()
            throw error
        }
    }

    /// Stops accepting requests, closes active sockets through the event-loop group,
    /// and waits for the connection task tree to unwind.
    public func stop() async throws {
        guard let group = eventLoopGroup else { return }
        let listener = self.listener
        let serverTask = self.serverTask
        let activeConnections = self.activeConnections
        self.listener = nil
        self.serverTask = nil
        self.activeConnections = nil
        self.eventLoopGroup = nil

        listener?.channel.close(promise: nil)
        activeConnections?.closeAll()
        serverTask?.cancel()
        await serverTask?.value
        try await group.shutdownGracefully()
    }

    public func boundPort() -> Int? {
        listener?.channel.localAddress?.port
    }

    private static func serve(
        listener: ListenerChannel,
        router: HTTPRouter,
        maximumBodyBytes: Int,
        maximumHeaderBytes: Int
    ) async {
        await withTaskGroup(of: Void.self) { group in
            do {
                try await listener.executeThenClose { inbound in
                    for try await connection in inbound {
                        group.addTask {
                            do {
                                try await Self.serveConnection(
                                    connection,
                                    router: router,
                                    maximumBodyBytes: maximumBodyBytes,
                                    maximumHeaderBytes: maximumHeaderBytes
                                )
                            } catch {
                                // A client failure must not stop the accept loop.
                            }
                        }
                    }
                }
            } catch {
                // Listener shutdown is handled by ApplicationLifecycle.stop().
            }
            await group.waitForAll()
        }
    }

    private static func serveConnection(
        _ connection: RequestChannel,
        router: HTTPRouter,
        maximumBodyBytes: Int,
        maximumHeaderBytes: Int
    ) async throws {
        try await connection.executeThenClose { inbound, outbound in
            var currentHead: HTTPRequestHead?
            var body = Data()
            var rejected: HTTPError?

            for try await part in inbound {
                switch part {
                case .head(let head):
                    currentHead = head
                    body.removeAll(keepingCapacity: true)
                    let headerBytes = head.headers.reduce(0) { total, header in
                        total + header.name.utf8.count + header.value.utf8.count
                    }
                    rejected = headerBytes > maximumHeaderBytes ? .headersTooLarge : nil

                case .body(let buffer):
                    if rejected == nil {
                        if buffer.readableBytes > maximumBodyBytes - body.count {
                            rejected = .payloadTooLarge
                        } else {
                            body.append(contentsOf: buffer.readableBytesView)
                        }
                    }

                case .end:
                    guard let head = currentHead else { continue }
                    let response: HTTPResponse
                    if let rejected {
                        response = rejected.response
                    } else {
                        do {
                            let requestHeaders = try Self.normalizedHeaders(head.headers)
                            let request = try HTTPRequest(
                                method: HTTPMethod(head.method.rawValue),
                                target: head.uri,
                                headers: requestHeaders,
                                body: body
                            )
                            response = await router.handle(request)
                        } catch let error as HTTPError {
                            response = error.response
                        } catch {
                            response = HTTPError.badRequest("Malformed request").response
                        }
                    }
                    try await write(response, version: head.version, keepAlive: head.isKeepAlive, through: outbound, allocator: connection.channel.allocator)
                    currentHead = nil
                    body.removeAll(keepingCapacity: true)
                    rejected = nil
                }
            }
        }
    }

    private static func write(
        _ response: HTTPResponse,
        version: HTTPVersion,
        keepAlive: Bool,
        through outbound: NIOAsyncChannelOutboundWriter<ResponsePart>,
        allocator: ByteBufferAllocator
    ) async throws {
        var headers = HTTPHeaders()
        for (name, value) in response.headers {
            headers.add(name: name, value: value)
        }
        if !response.headers.keys.contains(where: { $0.caseInsensitiveCompare("content-length") == .orderedSame }) {
            headers.add(name: "content-length", value: String(response.body.count))
        }
        if !keepAlive { headers.replaceOrAdd(name: "connection", value: "close") }

        let head = HTTPResponseHead(
            version: version,
            status: HTTPResponseStatus(statusCode: response.status),
            headers: headers
        )
        var body = allocator.buffer(capacity: response.body.count)
        body.writeBytes(response.body)
        try await outbound.write(contentsOf: [.head(head), .body(body), .end(nil)])
    }

    private static func normalizedHeaders(_ headers: HTTPHeaders) throws -> [String: String] {
        let singleValueHeaders: Set<String> = ["authorization", "content-length", "host", "transfer-encoding"]
        var values: [String: String] = [:]
        for (rawName, value) in headers {
            let name = rawName.lowercased()
            if let existing = values[name] {
                guard !singleValueHeaders.contains(name) else {
                    throw HTTPError.badRequest("Duplicate \(name) header")
                }
                values[name] = "\(existing), \(value)"
            } else {
                values[name] = value
            }
        }
        return values
    }
}

/// Tracks child sockets while they cross between event loops and lifecycle code.
/// The lock protects only the set; it is never held during I/O or an await.
private final class ActiveConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]

    func insert(_ channel: Channel) {
        lock.lock()
        channels[ObjectIdentifier(channel)] = channel
        lock.unlock()
    }

    func remove(_ channel: Channel) {
        lock.lock()
        channels.removeValue(forKey: ObjectIdentifier(channel))
        lock.unlock()
    }

    func closeAll() {
        lock.lock()
        let active = Array(channels.values)
        lock.unlock()
        for channel in active { channel.close(promise: nil) }
    }
}

private final class HTTPResponsePartBridge: ChannelOutboundHandler, Sendable {
    typealias OutboundIn = ResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch Self.unwrapOutboundIn(data) {
        case .head(let head):
            context.write(Self.wrapOutboundOut(.head(head)), promise: promise)
        case .body(let body):
            context.write(Self.wrapOutboundOut(.body(.byteBuffer(body))), promise: promise)
        case .end(let trailers):
            context.write(Self.wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}

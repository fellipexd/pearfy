import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import NIOSSL
import PearfyContext
import PearfyGameServer

/// TLS-only WebSocket gateway. Authentication and game command handling remain app-owned.
public struct GameServerWebSocketConfiguration: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let path: String
    public let certificatePath: String
    public let privateKeyPath: String
    public let maximumConnections: Int
    public let maximumMessageBytes: Int
    public let maximumBufferedFramesPerConnection: Int
    public let maximumAggregateBufferedPayloadBytes: Int
    public let maximumMessagesPerSecondPerConnection: Int
    public let idleReadTimeoutSeconds: Int

    public init(
        host: String = "127.0.0.1", port: Int = 8443, path: String = "/gameserver",
        certificatePath: String, privateKeyPath: String, maximumConnections: Int = 256,
        maximumMessageBytes: Int = 65_536, maximumBufferedFramesPerConnection: Int = 10,
        maximumAggregateBufferedPayloadBytes: Int = 268_435_456,
        maximumMessagesPerSecondPerConnection: Int = 120, idleReadTimeoutSeconds: Int = 60
    ) throws {
        guard !host.isEmpty, (0...65_535).contains(port), path.hasPrefix("/"),
              !path.contains("?") && !path.contains("#"), path.utf8.count <= 256,
              !certificatePath.isEmpty, !privateKeyPath.isEmpty,
              (1...100_000).contains(maximumConnections), (1...1_048_576).contains(maximumMessageBytes),
              (2...1_024).contains(maximumBufferedFramesPerConnection),
              (1_048_576...17_179_869_184).contains(maximumAggregateBufferedPayloadBytes),
              maximumConnections <= maximumAggregateBufferedPayloadBytes / maximumMessageBytes / (maximumBufferedFramesPerConnection + 3),
              (1...100_000).contains(maximumMessagesPerSecondPerConnection), (5...3_600).contains(idleReadTimeoutSeconds) else {
            throw GameServerWebSocketError.invalidConfiguration
        }
        self.host = host; self.port = port; self.path = path
        self.certificatePath = certificatePath; self.privateKeyPath = privateKeyPath
        self.maximumConnections = maximumConnections; self.maximumMessageBytes = maximumMessageBytes
        self.maximumBufferedFramesPerConnection = maximumBufferedFramesPerConnection
        self.maximumAggregateBufferedPayloadBytes = maximumAggregateBufferedPayloadBytes
        self.maximumMessagesPerSecondPerConnection = maximumMessagesPerSecondPerConnection
        self.idleReadTimeoutSeconds = idleReadTimeoutSeconds
    }
}

public enum GameServerWebSocketError: Error, Sendable, Equatable {
    case invalidConfiguration
    case tlsConfiguration
    case listenerAlreadyRunning
    case shutdown(String)
}

private enum GatewayUpgrade: Sendable {
    case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, GameSessionPrincipal)
    case http(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
}
private typealias GatewayListener = NIOAsyncChannel<EventLoopFuture<GatewayUpgrade>, Never>
private typealias GatewayConnectionID = ObjectIdentifier

/// Optional WSS listener with bounded admission, frame size and per-connection rate.
/// It never logs credentials or game payloads. The app callback validates a bearer ticket
/// and returns a principal; each accepted message is handed to the app's authoritative handler.
public actor GameServerWebSocketGateway: ApplicationLifecycle {
    public nonisolated let name = "Pearfy game server WSS gateway"

    public typealias Authorize = @Sendable (_ bearerToken: String) async -> GameSessionPrincipal?
    public typealias MessageHandler = @Sendable (_ principal: GameSessionPrincipal, _ payload: Data) async throws -> Data?

    private let configuration: GameServerWebSocketConfiguration
    private let authorize: Authorize
    private let onMessage: MessageHandler
    private var group: MultiThreadedEventLoopGroup?
    private var listener: GatewayListener?
    private var acceptTask: Task<Void, Never>?
    private var connections: GatewayConnections?

    public init(
        configuration: GameServerWebSocketConfiguration,
        authorize: @escaping Authorize,
        onMessage: @escaping MessageHandler
    ) {
        self.configuration = configuration; self.authorize = authorize; self.onMessage = onMessage
    }

    public func boundPort() -> Int? { listener?.channel.localAddress?.port }

    public func start() async throws {
        guard listener == nil else { throw GameServerWebSocketError.listenerAlreadyRunning }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connections = GatewayConnections(maximum: configuration.maximumConnections,
                                             maximumMessagesPerSecond: configuration.maximumMessagesPerSecondPerConnection)
        do {
            var tls = TLSConfiguration.makeServerConfiguration(
                certificateChain: try NIOSSLCertificate.fromPEMFile(configuration.certificatePath).map(NIOSSLCertificateSource.certificate),
                privateKey: .privateKey(try NIOSSLPrivateKey(file: configuration.privateKeyPath, format: .pem))
            )
            tls.minimumTLSVersion = .tlsv12
            let context: NIOSSLContext
            do { context = try NIOSSLContext(configuration: tls) }
            catch { throw GameServerWebSocketError.tlsConfiguration }
            let config = configuration
            let authorize = self.authorize
            let gateway: GatewayListener = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(host: configuration.host, port: configuration.port) { channel in
                    let id = ObjectIdentifier(channel)
                    guard connections.admit(id, channel: channel) else {
                        channel.close(promise: nil)
                        return channel.eventLoop.makeFailedFuture(GameServerWebSocketError.invalidConfiguration)
                    }
                    channel.closeFuture.whenComplete { _ in connections.remove(id) }
                    do {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                        try channel.pipeline.syncOperations.addHandler(IdleStateHandler(readTimeout: .seconds(Int64(config.idleReadTimeoutSeconds))))
                        try channel.pipeline.syncOperations.addHandler(ReadIdleCloseHandler())
                        let upgrader = NIOTypedWebSocketServerUpgrader<GatewayUpgrade>(
                            maxFrameSize: config.maximumMessageBytes,
                            shouldUpgrade: { channel, head in
                                guard head.method == .GET,
                                      head.uri == config.path,
                                      let token = Self.bearer(head.headers) else {
                                    return channel.eventLoop.makeSucceededFuture(nil)
                                }
                                let promise = channel.eventLoop.makePromise(of: HTTPHeaders?.self)
                                Task {
                                    let principal = await authorize(token)
                                    channel.eventLoop.execute {
                                        guard let principal, connections.setPrincipal(principal, for: id) else {
                                            promise.succeed(nil)
                                            return
                                        }
                                        promise.succeed(HTTPHeaders())
                                    }
                                }
                                return promise.futureResult
                            },
                            upgradePipelineHandler: { channel, _ in
                                guard let principal = connections.principal(for: ObjectIdentifier(channel)) else {
                                    return channel.eventLoop.makeFailedFuture(GameServerWebSocketError.invalidConfiguration)
                                }
                                connections.clearPrincipal(for: ObjectIdentifier(channel))
                                return channel.eventLoop.makeCompletedFuture {
                                    .websocket(try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
                                        wrappingChannelSynchronously: channel,
                                        configuration: .init(backPressureStrategy: .init(
                                            lowWatermark: config.maximumBufferedFramesPerConnection / 2,
                                            highWatermark: config.maximumBufferedFramesPerConnection
                                        ))
                                    ), principal)
                                }
                            }
                        )
                        let upgrade = NIOTypedHTTPServerUpgradeConfiguration<GatewayUpgrade>(
                            upgraders: [upgrader],
                            notUpgradingCompletionHandler: { channel in
                                channel.eventLoop.makeCompletedFuture {
                                    try channel.pipeline.syncOperations.addHandler(HTTPResponseBridge())
                                    return .http(try NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>(wrappingChannelSynchronously: channel))
                                }
                            }
                        )
                        let upgradeResult = try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                            configuration: .init(upgradeConfiguration: upgrade)
                        )
                        return channel.eventLoop.makeSucceededFuture(upgradeResult)
                    } catch {
                        connections.remove(id)
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
            self.group = group; self.listener = gateway; self.connections = connections
            let authorizeMessage = self.onMessage
            self.acceptTask = Task {
                await Self.accept(gateway, connections: connections, authorizeMessage: authorizeMessage,
                                  maximumMessageBytes: config.maximumMessageBytes)
            }
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    public func stop() async throws {
        guard let group else { return }
        let listener = self.listener; let task = acceptTask; let connections = self.connections
        self.group = nil; self.listener = nil; self.acceptTask = nil; self.connections = nil
        listener?.channel.close(promise: nil); connections?.closeAll(); task?.cancel(); await task?.value
        do { try await group.shutdownGracefully() }
        catch { throw GameServerWebSocketError.shutdown(String(describing: error)) }
    }

    private static func bearer(_ headers: HTTPHeaders) -> String? {
        let values = headers["authorization"]
        guard values.count == 1, values[0].utf8.count <= 4_096,
              values[0].hasPrefix("Bearer ") else { return nil }
        let token = String(values[0].dropFirst(7))
        return token.isEmpty ? nil : token
    }

    private static func accept(_ listener: GatewayListener, connections: GatewayConnections,
                               authorizeMessage: @escaping MessageHandler, maximumMessageBytes: Int) async {
        do {
            try await listener.executeThenClose { inbound in
                try await withThrowingTaskGroup(of: Void.self) { tasks in
                    for try await upgrade in inbound { tasks.addTask { await Self.handle(upgrade, connections: connections,
                                                                                         onMessage: authorizeMessage,
                                                                                         maximumMessageBytes: maximumMessageBytes) } }
                    try await tasks.waitForAll()
                }
            }
        } catch { /* stop() owns listener shutdown; no payload or credential is logged. */ }
    }

    private static func handle(_ future: EventLoopFuture<GatewayUpgrade>, connections: GatewayConnections,
                               onMessage: @escaping MessageHandler, maximumMessageBytes: Int) async {
        do {
            switch try await future.get() {
            case .websocket(let channel, let principal):
                try await channel.executeThenClose { inbound, outbound in
                    var fragments = Data()
                    var fragmentedOpcode: WebSocketOpcode?
                    var messageCount = 0
                    var windowStart = ContinuousClock.now
                    for try await frame in inbound {
                        switch frame.opcode {
                        case .ping:
                            try await outbound.write(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData))
                        case .connectionClose:
                            var data = frame.unmaskedData
                            let closeCode = data.readSlice(length: 2) ?? ByteBuffer()
                            try await outbound.write(WebSocketFrame(fin: true, opcode: .connectionClose, data: closeCode))
                            return
                        case .text, .binary:
                            guard fragmentedOpcode == nil else { return }
                            fragmentedOpcode = frame.opcode
                            fragments.removeAll(keepingCapacity: true)
                            fragments.append(contentsOf: frame.unmaskedData.readableBytesView)
                        case .continuation:
                            guard fragmentedOpcode != nil else { return }
                            fragments.append(contentsOf: frame.unmaskedData.readableBytesView)
                        case .pong: continue
                        default: return
                        }
                        guard fragments.count <= maximumMessageBytes else { return }
                        guard let opcode = fragmentedOpcode, frame.fin else { continue }
                        guard opcode == .text || opcode == .binary else { return }
                        if ContinuousClock.now - windowStart >= .seconds(1) { messageCount = 0; windowStart = .now }
                        messageCount += 1
                        guard messageCount <= connections.maximumMessagesPerSecond else { return }
                        if let response = try await onMessage(principal, fragments) {
                            guard response.count <= maximumMessageBytes else { return }
                            var buffer = channel.channel.allocator.buffer(capacity: response.count)
                            buffer.writeBytes(response)
                            try await outbound.write(WebSocketFrame(fin: true, opcode: .binary, data: buffer))
                        }
                        fragmentedOpcode = nil; fragments.removeAll(keepingCapacity: true)
                    }
                }
            case .http(let channel):
                try await channel.executeThenClose { _, outbound in
                    var headers = HTTPHeaders(); headers.add(name: "Connection", value: "close"); headers.add(name: "Content-Length", value: "0")
                    try await outbound.write(contentsOf: [.head(HTTPResponseHead(version: .http1_1, status: .notFound, headers: headers)), .end(nil)])
                }
            }
        } catch { /* A connection failure is isolated; never log game state. */ }
    }
}

private final class GatewayConnections: @unchecked Sendable {
    private let lock = NIOLock()
    private let maximum: Int
    let maximumMessagesPerSecond: Int
    private var channels: [GatewayConnectionID: Channel] = [:]
    private var principals: [GatewayConnectionID: GameSessionPrincipal] = [:]

    init(maximum: Int, maximumMessagesPerSecond: Int) {
        self.maximum = maximum; self.maximumMessagesPerSecond = maximumMessagesPerSecond
    }
    func admit(_ id: GatewayConnectionID, channel: Channel) -> Bool {
        lock.withLock { guard channels.count < maximum else { return false }; channels[id] = channel; return true }
    }
    func setPrincipal(_ principal: GameSessionPrincipal, for id: GatewayConnectionID) -> Bool {
        lock.withLock { guard channels[id] != nil else { return false }; principals[id] = principal; return true }
    }
    func principal(for id: GatewayConnectionID) -> GameSessionPrincipal? { lock.withLock { principals[id] } }
    func clearPrincipal(for id: GatewayConnectionID) { _ = lock.withLock { principals.removeValue(forKey: id) } }
    func remove(_ id: GatewayConnectionID) { lock.withLock { channels.removeValue(forKey: id); principals.removeValue(forKey: id) } }
    func closeAll() { let active = lock.withLock { Array(channels.values) }; active.forEach { $0.close(promise: nil) } }
}

private final class HTTPResponseBridge: ChannelOutboundHandler {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch Self.unwrapOutboundIn(data) {
        case .head(let head): context.write(Self.wrapOutboundOut(.head(head)), promise: promise)
        case .body(let buffer): context.write(Self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        case .end(let trailers): context.write(Self.wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}

private final class ReadIdleCloseHandler: ChannelInboundHandler {
    typealias InboundIn = NIOAny
    typealias InboundOut = NIOAny
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let idle = event as? IdleStateHandler.IdleStateEvent, case .read = idle {
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}

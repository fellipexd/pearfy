import Foundation
import NIOCore
import NIOPosix
import PearfyContext
import PearfyGameServer

public struct GameServerUDPConfiguration: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let maximumSessions: Int
    public let maximumDatagramBytes: Int
    public let maximumPayloadBytes: Int
    public let maximumBufferedDatagrams: Int
    public let maximumAggregateBufferedBytes: Int
    public let maximumPacketsPerSecond: Int
    public let maximumPacketsPerSecondPerSession: Int

    public init(
        host: String = "127.0.0.1",
        port: Int = 0,
        maximumSessions: Int = 2_048,
        maximumDatagramBytes: Int = 1_200,
        maximumBufferedDatagrams: Int = 64,
        maximumAggregateBufferedBytes: Int = 1_048_576,
        maximumPacketsPerSecond: Int = 100_000,
        maximumPacketsPerSecondPerSession: Int = 240
    ) throws {
        guard !host.isEmpty, (0...65_535).contains(port),
              (1...100_000).contains(maximumSessions),
              (GameServerSecureDatagramCodec.headerBytes + GameServerSecureDatagramCodec.authenticationTagBytes + 1...GameServerSecureDatagramCodec.maximumUDPPayloadBytes).contains(maximumDatagramBytes),
              (1...4_096).contains(maximumBufferedDatagrams),
              maximumDatagramBytes <= maximumAggregateBufferedBytes,
              maximumBufferedDatagrams <= maximumAggregateBufferedBytes / maximumDatagramBytes,
              (1...10_000_000).contains(maximumPacketsPerSecond),
              (1...100_000).contains(maximumPacketsPerSecondPerSession),
              maximumPacketsPerSecondPerSession <= maximumPacketsPerSecond else {
            throw GameServerUDPError.invalidConfiguration
        }
        self.host = host
        self.port = port
        self.maximumSessions = maximumSessions
        self.maximumDatagramBytes = maximumDatagramBytes
        self.maximumPayloadBytes = maximumDatagramBytes - GameServerSecureDatagramCodec.headerBytes - GameServerSecureDatagramCodec.authenticationTagBytes
        self.maximumBufferedDatagrams = maximumBufferedDatagrams
        self.maximumAggregateBufferedBytes = maximumAggregateBufferedBytes
        self.maximumPacketsPerSecond = maximumPacketsPerSecond
        self.maximumPacketsPerSecondPerSession = maximumPacketsPerSecondPerSession
    }
}

public enum GameServerUDPError: Error, Sendable, Equatable {
    case invalidConfiguration
    case listenerAlreadyRunning
    case sessionCapacityReached
    case duplicateSession
    case unknownSession
    case invalidSessionCodec
    case shutdown
}

private typealias UDPEnvelope = AddressedEnvelope<ByteBuffer>
private typealias UDPListener = NIOAsyncChannel<UDPEnvelope, UDPEnvelope>

private struct UDPSession: Sendable {
    let principal: GameSessionPrincipal
    let codec: GameServerSecureDatagramCodec
}

private final class UDPSessionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let maximum: Int
    private var sessions: [UUID: UDPSession] = [:]

    init(maximum: Int) { self.maximum = maximum }

    func add(_ session: UDPSession) throws {
        lock.lock()
        defer { lock.unlock() }
        guard sessions[session.codec.sessionID] == nil else { throw GameServerUDPError.duplicateSession }
        guard sessions.count < maximum else { throw GameServerUDPError.sessionCapacityReached }
        sessions[session.codec.sessionID] = session
    }

    func get(_ id: UUID) -> UDPSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[id]
    }

    func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeValue(forKey: id)
    }
}

struct GameServerUDPWindowLimiter {
    private struct Admission {
        let sessionID: UUID
        let admittedAt: ContinuousClock.Instant
    }

    private var admissions: [Admission] = []
    private var head = 0
    private var perSession: [UUID: Int] = [:]

    mutating func admit(
        sessionID: UUID,
        now: ContinuousClock.Instant = .now,
        maximumTotal: Int,
        maximumPerSession: Int
    ) -> Bool {
        while head < admissions.count, now - admissions[head].admittedAt >= .seconds(1) {
            let expired = admissions[head]
            head += 1
            let remaining = (perSession[expired.sessionID] ?? 1) - 1
            if remaining == 0 { perSession.removeValue(forKey: expired.sessionID) }
            else { perSession[expired.sessionID] = remaining }
        }
        compactIfNeeded()
        guard admissions.count - head < maximumTotal else { return false }
        let count = perSession[sessionID, default: 0]
        guard count < maximumPerSession else { return false }
        admissions.append(Admission(sessionID: sessionID, admittedAt: now))
        perSession[sessionID] = count + 1
        return true
    }

    private mutating func compactIfNeeded() {
        if head > 256 && head * 2 >= admissions.count {
            admissions.removeFirst(head)
            head = 0
        }
    }
}

/// Authenticated, encrypted UDP ingress. Session keys and principals are supplied only
/// after application-owned control-plane authorization. Inbound work is serial and
/// bounded by the async channel's watermarks; packets arriving faster than the server can
/// process are dropped by the kernel rather than accumulated as unbounded tasks.
public actor GameServerUDPServer: ApplicationLifecycle {
    public nonisolated let name = "Pearfy secure game server UDP listener"
    public typealias MessageHandler = @Sendable (_ principal: GameSessionPrincipal, _ payload: Data) async throws -> Data?

    private let configuration: GameServerUDPConfiguration
    private let onMessage: MessageHandler
    private let sessions: UDPSessionRegistry
    private var group: MultiThreadedEventLoopGroup?
    private var listener: UDPListener?
    private var receiveTask: Task<Void, Never>?

    public init(configuration: GameServerUDPConfiguration, onMessage: @escaping MessageHandler) {
        self.configuration = configuration
        self.onMessage = onMessage
        self.sessions = UDPSessionRegistry(maximum: configuration.maximumSessions)
    }

    public func boundPort() -> Int? { listener?.channel.localAddress?.port }

    public func register(sessionID: UUID, principal: GameSessionPrincipal, codec: GameServerSecureDatagramCodec) throws {
        guard sessionID == codec.sessionID, codec.acceptsClientPackets,
              codec.maximumPayloadBytes <= configuration.maximumPayloadBytes else {
            throw GameServerUDPError.invalidSessionCodec
        }
        try sessions.add(UDPSession(principal: principal, codec: codec))
    }

    public func unregister(sessionID: UUID) { sessions.remove(sessionID) }

    public func start() async throws {
        guard listener == nil else { throw GameServerUDPError.listenerAlreadyRunning }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let config = configuration
            let listener: UDPListener = try await DatagramBootstrap(group: group)
                .bind(host: config.host, port: config.port) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<UDPEnvelope, UDPEnvelope>(
                            wrappingChannelSynchronously: channel,
                            configuration: .init(backPressureStrategy: .init(
                                lowWatermark: max(1, config.maximumBufferedDatagrams / 2),
                                highWatermark: config.maximumBufferedDatagrams
                            ))
                        )
                    }
                }
            self.group = group
            self.listener = listener
            let sessions = self.sessions
            let onMessage = self.onMessage
            self.receiveTask = Task {
                await Self.receive(listener, sessions: sessions, configuration: config, onMessage: onMessage)
            }
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    public func stop() async throws {
        guard let group else { return }
        let listener = self.listener
        let task = receiveTask
        self.group = nil
        self.listener = nil
        self.receiveTask = nil
        listener?.channel.close(promise: nil)
        task?.cancel()
        await task?.value
        do { try await group.shutdownGracefully() }
        catch { throw GameServerUDPError.shutdown }
    }

    private static func receive(
        _ listener: UDPListener,
        sessions: UDPSessionRegistry,
        configuration: GameServerUDPConfiguration,
        onMessage: @escaping MessageHandler
    ) async {
        var ingressLimiter = GameServerUDPWindowLimiter()
        var authenticatedLimiter = GameServerUDPWindowLimiter()
        let ingressBudgetID = UUID()
        do {
            try await listener.executeThenClose { inbound, outbound in
                for try await envelope in inbound {
                    let byteCount = envelope.data.readableBytes
                    guard byteCount >= GameServerSecureDatagramCodec.headerBytes + GameServerSecureDatagramCodec.authenticationTagBytes,
                          byteCount <= configuration.maximumDatagramBytes,
                          ingressLimiter.admit(
                            sessionID: ingressBudgetID,
                            maximumTotal: configuration.maximumPacketsPerSecond,
                            maximumPerSession: configuration.maximumPacketsPerSecond
                          ) else { continue }
                    let packet = Data(envelope.data.readableBytesView)
                    guard let sessionID = GameServerSecureDatagramCodec.sessionID(in: packet),
                          let session = sessions.get(sessionID) else { continue }
                    let plaintext: Data
                    do { plaintext = try session.codec.open(packet) }
                    catch { continue }
                    // Unauthenticated datagrams consume only the global crypto-work
                    // budget above. Apply the fairness quota to a session only after
                    // its AEAD tag and replay sequence have been accepted.
                    guard authenticatedLimiter.admit(
                        sessionID: sessionID,
                        maximumTotal: configuration.maximumPacketsPerSecond,
                        maximumPerSession: configuration.maximumPacketsPerSecondPerSession
                    ) else { continue }
                    do {
                        guard let response = try await onMessage(session.principal, plaintext) else { continue }
                        guard response.count <= plaintext.count,
                              response.count <= session.codec.maximumPayloadBytes else { continue }
                        let responsePacket = try session.codec.seal(response)
                        // Do not amplify a spoofable UDP source address. This v1 listener
                        // has no address-validation handshake, so replies cannot exceed
                        // the authenticated plaintext that triggered them.
                        var buffer = ByteBufferAllocator().buffer(capacity: responsePacket.count)
                        buffer.writeBytes(responsePacket)
                        try await outbound.write(UDPEnvelope(remoteAddress: envelope.remoteAddress, data: buffer))
                    } catch {
                        // Drop failed commands and responses without logging private payloads.
                    }
                }
            }
        } catch {
            // Listener shutdown owns cancellation; datagram failures are intentionally silent.
        }
    }
}

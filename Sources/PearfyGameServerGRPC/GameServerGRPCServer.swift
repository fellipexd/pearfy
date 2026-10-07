import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import PearfyGameServer

/// Stable unary control-plane methods exposed by Pearfy's versioned matchmaking and game services.
@available(macOS 15, iOS 18, *)
public enum GameServerGRPCMethod: String, Sendable, CaseIterable {
    case findGame
    case createRoom
    case join
    case leave
}

/// Bounds and TLS files for the optional gRPC control plane.
@available(macOS 15, iOS 18, *)
public struct GameServerGRPCConfiguration: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let certificateChainPath: String
    public let privateKeyPath: String
    public let maximumMessageBytes: Int
    public let maximumConcurrentStreamsPerConnection: Int
    public let maximumConnections: Int
    public let maximumAggregateInFlightPayloadBytes: Int

    public init(
        host: String = "0.0.0.0",
        port: Int = 8443,
        certificateChainPath: String,
        privateKeyPath: String,
        maximumMessageBytes: Int = 65_536,
        maximumConcurrentStreamsPerConnection: Int = 16,
        maximumConnections: Int = 128,
        maximumAggregateInFlightPayloadBytes: Int = 268_435_456
    ) throws {
        guard !host.isEmpty, host.utf8.count <= 253,
              (0...65_535).contains(port),
              !certificateChainPath.isEmpty, !privateKeyPath.isEmpty,
              FileManager.default.isReadableFile(atPath: certificateChainPath),
              FileManager.default.isReadableFile(atPath: privateKeyPath),
              (1_024...16_777_216).contains(maximumMessageBytes),
              (1...1_024).contains(maximumConcurrentStreamsPerConnection),
              (1...100_000).contains(maximumConnections),
              (1_048_576...17_179_869_184).contains(maximumAggregateInFlightPayloadBytes),
              maximumConnections <= maximumAggregateInFlightPayloadBytes / 2 / maximumConcurrentStreamsPerConnection / maximumMessageBytes else {
            throw GameServerGRPCError.invalidConfiguration
        }
        self.host = host
        self.port = port
        self.certificateChainPath = certificateChainPath
        self.privateKeyPath = privateKeyPath
        self.maximumMessageBytes = maximumMessageBytes
        self.maximumConcurrentStreamsPerConnection = maximumConcurrentStreamsPerConnection
        self.maximumConnections = maximumConnections
        self.maximumAggregateInFlightPayloadBytes = maximumAggregateInFlightPayloadBytes
    }
}

public enum GameServerGRPCError: Error, Sendable, Equatable {
    case invalidConfiguration
    case alreadyStarted
}

/// Lifecycle-owning TLS gRPC server. The application callback owns matchmaking,
/// room policy, ticket validation and the authoritative response payload.
@available(macOS 15, iOS 18, *)
public actor GameServerGRPCServer {
    public typealias Authorize = @Sendable (_ bearerAuthorization: String?) async throws -> GameSessionPrincipal
    public typealias Dispatch = @Sendable (
        _ method: GameServerGRPCMethod,
        _ payload: Data,
        _ principal: GameSessionPrincipal
    ) async throws -> Data

    private let connectionLimiter: GRPCConnectionLimiter

    private let transport: HTTP2ServerTransport.Posix
    private let server: GRPCServer<HTTP2ServerTransport.Posix>
    private var serveTask: Task<Void, Error>?

    public init(
        configuration: GameServerGRPCConfiguration,
        authorize: @escaping Authorize,
        dispatch: @escaping Dispatch
    ) {
        var transportConfig = HTTP2ServerTransport.Posix.Config.defaults
        transportConfig.rpc.maxRequestPayloadSize = configuration.maximumMessageBytes
        transportConfig.http2.maxConcurrentStreams = configuration.maximumConcurrentStreamsPerConnection
        let connectionLimiter = GRPCConnectionLimiter(maximumConnections: configuration.maximumConnections)
        transportConfig.channelDebuggingCallbacks.onAcceptTCPConnection = { channel in
            guard connectionLimiter.admit() else { return channel.close() }
            channel.closeFuture.whenComplete { _ in connectionLimiter.release() }
            return channel.eventLoop.makeSucceededFuture(())
        }

        self.transport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: configuration.host, port: configuration.port),
            transportSecurity: .tls(
                certificateChain: [.file(path: configuration.certificateChainPath, format: .pem)],
                privateKey: .file(path: configuration.privateKeyPath, format: .pem),
                configure: { $0.requireALPN = true }
            ),
            config: transportConfig
        )
        self.server = GRPCServer(
            transport: self.transport,
            services: [
                MatchmakingControlService(authorize: authorize, dispatch: dispatch, maximumMessageBytes: configuration.maximumMessageBytes),
                GameSessionControlService(authorize: authorize, dispatch: dispatch, maximumMessageBytes: configuration.maximumMessageBytes)
            ]
        )
        self.connectionLimiter = connectionLimiter
    }

    /// Starts listening and returns the bound address, including the selected port when port is 0.
    public func start() async throws -> String {
        guard serveTask == nil else { throw GameServerGRPCError.alreadyStarted }
        serveTask = Task { try await server.serve() }
        return try await transport.listeningAddress.description
    }

    /// Stops accepting new RPCs and waits for in-flight handlers to drain.
    public func stop() async throws {
        guard let serveTask else { return }
        server.beginGracefulShutdown()
        try await serveTask.value
        self.serveTask = nil
    }
}

private final class GRPCConnectionLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumConnections: Int
    private var activeConnections = 0

    init(maximumConnections: Int) { self.maximumConnections = maximumConnections }

    func admit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeConnections < maximumConnections else { return false }
        activeConnections += 1
        return true
    }

    func release() {
        lock.lock()
        activeConnections = max(0, activeConnections - 1)
        lock.unlock()
    }
}

@available(macOS 15, iOS 18, *)
private struct MatchmakingControlService: Pearfy_Matchmaking_V1_Matchmaking.ServiceProtocol {
    let authorize: GameServerGRPCServer.Authorize
    let dispatch: GameServerGRPCServer.Dispatch
    let maximumMessageBytes: Int

    func findGame(request: ServerRequest<Pearfy_Common_V1_ControlRequest>, context: ServerContext) async throws -> ServerResponse<Pearfy_Common_V1_ControlResponse> {
        ServerResponse(message: try await respond(.findGame, request: request))
    }

    func createRoom(request: ServerRequest<Pearfy_Common_V1_ControlRequest>, context: ServerContext) async throws -> ServerResponse<Pearfy_Common_V1_ControlResponse> {
        ServerResponse(message: try await respond(.createRoom, request: request))
    }

    func findGame(request: StreamingServerRequest<Pearfy_Common_V1_ControlRequest>, context: ServerContext) async throws -> StreamingServerResponse<Pearfy_Common_V1_ControlResponse> {
        let single = try await ServerRequest(stream: request)
        return StreamingServerResponse(single: ServerResponse(message: try await respond(.findGame, request: single)))
    }

    func createRoom(request: StreamingServerRequest<Pearfy_Common_V1_ControlRequest>, context: ServerContext) async throws -> StreamingServerResponse<Pearfy_Common_V1_ControlResponse> {
        let single = try await ServerRequest(stream: request)
        return StreamingServerResponse(single: ServerResponse(message: try await respond(.createRoom, request: single)))
    }

    private func respond(_ method: GameServerGRPCMethod, request: ServerRequest<Pearfy_Common_V1_ControlRequest>) async throws -> Pearfy_Common_V1_ControlResponse {
        try await controlResponse(method, request: request, authorize: authorize, dispatch: dispatch, maximumMessageBytes: maximumMessageBytes)
    }
}

@available(macOS 15, iOS 18, *)
private struct GameSessionControlService: Pearfy_Game_V1_GameSession.ServiceProtocol {
    let authorize: GameServerGRPCServer.Authorize
    let dispatch: GameServerGRPCServer.Dispatch
    let maximumMessageBytes: Int

    func join(request: ServerRequest<Pearfy_Common_V1_ControlRequest>, context: ServerContext) async throws -> ServerResponse<Pearfy_Common_V1_ControlResponse> {
        ServerResponse(message: try await respond(.join, request: request))
    }

    func leave(request: ServerRequest<Pearfy_Common_V1_ControlRequest>, context: ServerContext) async throws -> ServerResponse<Pearfy_Common_V1_ControlResponse> {
        ServerResponse(message: try await respond(.leave, request: request))
    }

    func join(request: StreamingServerRequest<Pearfy_Common_V1_ControlRequest>, context: ServerContext) async throws -> StreamingServerResponse<Pearfy_Common_V1_ControlResponse> {
        let single = try await ServerRequest(stream: request)
        return StreamingServerResponse(single: ServerResponse(message: try await respond(.join, request: single)))
    }

    func leave(request: StreamingServerRequest<Pearfy_Common_V1_ControlRequest>, context: ServerContext) async throws -> StreamingServerResponse<Pearfy_Common_V1_ControlResponse> {
        let single = try await ServerRequest(stream: request)
        return StreamingServerResponse(single: ServerResponse(message: try await respond(.leave, request: single)))
    }

    private func respond(_ method: GameServerGRPCMethod, request: ServerRequest<Pearfy_Common_V1_ControlRequest>) async throws -> Pearfy_Common_V1_ControlResponse {
        try await controlResponse(method, request: request, authorize: authorize, dispatch: dispatch, maximumMessageBytes: maximumMessageBytes)
    }
}

@available(macOS 15, iOS 18, *)
private func controlResponse(
    _ method: GameServerGRPCMethod,
    request: ServerRequest<Pearfy_Common_V1_ControlRequest>,
    authorize: GameServerGRPCServer.Authorize,
    dispatch: GameServerGRPCServer.Dispatch,
    maximumMessageBytes: Int
) async throws -> Pearfy_Common_V1_ControlResponse {
    guard request.message.payload.count <= maximumMessageBytes else {
        throw RPCError(code: .resourceExhausted, message: "Game server control payload exceeds configured limit")
    }
    var authorizationValues = request.metadata[stringValues: "authorization"].makeIterator()
    guard let value = authorizationValues.next(),
          authorizationValues.next() == nil,
          value.utf8.count <= 4_096,
          value.lowercased().hasPrefix("bearer ") else {
        throw RPCError(code: .unauthenticated, message: "Unauthenticated")
    }

    let principal: GameSessionPrincipal
    do { principal = try await authorize(value) }
    catch { throw RPCError(code: .unauthenticated, message: "Unauthenticated") }

    let responsePayload: Data
    do { responsePayload = try await dispatch(method, request.message.payload, principal) }
    catch { throw RPCError(code: .internalError, message: "Game server control request failed") }
    guard responsePayload.count <= maximumMessageBytes else {
        throw RPCError(code: .resourceExhausted, message: "Game server control response exceeds configured limit")
    }
    return Pearfy_Common_V1_ControlResponse.with { $0.payload = responsePayload }
}

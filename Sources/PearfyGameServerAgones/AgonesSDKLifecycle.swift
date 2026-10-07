import Foundation
import PearfyCloud
import PearfyContext

public enum AgonesSDKError: Error, Sendable, Equatable {
    case invalidConfiguration
    case unavailable
    case rejected(statusCode: Int)
    case invalidResponse
    case responseTooLarge
    case invalidLifecycleTransition
}

/// Local Agones SDK sidecar connection configuration. The SDK REST interface is loopback-only.
public struct AgonesSDKConfiguration: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let healthIntervalSeconds: Int
    public let maximumGameServerResponseBytes: Int

    public init(host: String = "127.0.0.1", port: Int, healthIntervalSeconds: Int = 5,
                maximumGameServerResponseBytes: Int = 65_536) throws {
        let normalized = host.lowercased()
        let loopback = normalized == "localhost" || normalized == "::1" || Self.isIPv4Loopback(normalized)
        guard loopback, (1...65_535).contains(port), (1...300).contains(healthIntervalSeconds),
              (1_024...1_048_576).contains(maximumGameServerResponseBytes) else {
            throw AgonesSDKError.invalidConfiguration
        }
        self.host = host; self.port = port; self.healthIntervalSeconds = healthIntervalSeconds
        self.maximumGameServerResponseBytes = maximumGameServerResponseBytes
    }

    /// Reads the sidecar's dynamic REST port without retaining arbitrary environment values.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard let rawPort = environment["AGONES_SDK_HTTP_PORT"], rawPort.utf8.count <= 5,
              let port = Int(rawPort) else { throw AgonesSDKError.invalidConfiguration }
        return try Self(port: port)
    }

    fileprivate var baseURL: URL {
        var components = URLComponents()
        components.scheme = "http"; components.host = host; components.port = port
        return components.url!
    }

    private static func isIPv4Loopback(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4, components[0] == "127" else { return false }
        return components.allSatisfy { part in
            guard part.utf8.allSatisfy({ (48...57).contains($0) }), let octet = Int(part) else { return false }
            return (0...255).contains(octet)
        }
    }
}

public struct AgonesGameServerSnapshot: Decodable, Sendable, Equatable {
    public struct Port: Decodable, Sendable, Equatable {
        public let name: String?
        public let port: Int
    }
    public struct Status: Decodable, Sendable, Equatable {
        public let state: String?
        public let address: String?
        public let ports: [Port]?
    }
    public struct Metadata: Decodable, Sendable, Equatable {
        public let name: String?
        public let namespace: String?
    }

    public let status: Status
    public let objectMeta: Metadata?

    enum CodingKeys: String, CodingKey {
        case status
        case objectMeta = "object_meta"
    }
}

public enum AgonesSDKRequestedState: String, Sendable, Equatable {
    case starting
    case ready
    case allocated
    case shutdown
}

/// Opt-in sidecar SDK lifecycle adapter. Fleet/GameServerAllocation orchestration remains
/// an external control-plane responsibility; this client only talks to the local SDK sidecar.
public actor AgonesSDKLifecycle: ApplicationLifecycle {
    public nonisolated let name = "Pearfy Agones SDK lifecycle"

    private let configuration: AgonesSDKConfiguration
    private let http: CloudHTTPClient
    private var heartbeatTask: Task<Void, Never>?
    private var requestedState: AgonesSDKRequestedState = .starting

    public init(configuration: AgonesSDKConfiguration, transport: (any CloudHTTPTransport)? = nil) {
        self.configuration = configuration
        self.http = CloudHTTPClient(
            transport: transport,
            retryPolicy: HTTPRetryPolicy(maximumAttempts: 1),
            maximumConcurrentRequests: 2,
            maximumQueuedRequests: 2
        )
    }

    public var state: AgonesSDKRequestedState { requestedState }

    /// Starts a bounded health heartbeat. Readiness is explicitly published with `ready()`
    /// after the game has finished loading its content and transport.
    public func start() async throws {
        guard heartbeatTask == nil, requestedState == .starting else { throw AgonesSDKError.invalidLifecycleTransition }
        do { try await post("/health") }
        catch { throw AgonesSDKError.unavailable }
        let interval = configuration.healthIntervalSeconds
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
                guard !Task.isCancelled else { return }
                await self?.sendHeartbeat()
            }
        }
    }

    /// Marks the dedicated process ready after local application initialization completes.
    public func ready() async throws {
        guard heartbeatTask != nil, requestedState == .starting else { throw AgonesSDKError.invalidLifecycleTransition }
        try await post("/ready")
        requestedState = .ready
    }

    /// Marks the GameServer allocated when an application-owned matchmaker deliberately
    /// uses SDK Allocate instead of Agones GameServerAllocation.
    public func allocate() async throws {
        guard requestedState == .ready else { throw AgonesSDKError.invalidLifecycleTransition }
        try await post("/allocate")
        requestedState = .allocated
    }

    public func gameServer() async throws -> AgonesGameServerSnapshot {
        let response = try await send(path: "/gameserver", method: "GET", body: nil)
        guard response.body.count <= configuration.maximumGameServerResponseBytes else { throw AgonesSDKError.responseTooLarge }
        do { return try JSONDecoder().decode(AgonesGameServerSnapshot.self, from: response.body) }
        catch { throw AgonesSDKError.invalidResponse }
    }

    /// Stops heartbeat and asks the sidecar to shut down. Repeated shutdown calls are idempotent.
    public func shutdown() async throws {
        guard requestedState != .shutdown else { return }
        guard requestedState == .ready || requestedState == .allocated else { throw AgonesSDKError.invalidLifecycleTransition }
        let heartbeat = heartbeatTask
        heartbeatTask = nil
        heartbeat?.cancel()
        await heartbeat?.value
        try await post("/shutdown")
        requestedState = .shutdown
    }

    public func stop() async throws {
        switch requestedState {
        case .starting:
            let heartbeat = heartbeatTask
            heartbeatTask = nil
            heartbeat?.cancel()
            await heartbeat?.value
        case .ready, .allocated:
            try await shutdown()
        case .shutdown:
            heartbeatTask?.cancel(); heartbeatTask = nil
        }
    }

    private func sendHeartbeat() async {
        guard requestedState != .shutdown else { return }
        do { try await post("/health") }
        catch { /* Agones detects health timeout; never log sidecar or game payloads. */ }
    }

    private func post(_ path: String) async throws {
        _ = try await send(path: path, method: "POST", body: Data("{}".utf8))
    }

    private func send(path: String, method: String, body: Data?) async throws -> CloudHTTPResponse {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw AgonesSDKError.invalidConfiguration
        }
        components.path = path
        guard let url = components.url else { throw AgonesSDKError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 2
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let response: CloudHTTPResponse
        do { response = try await http.send(request) }
        catch { throw AgonesSDKError.unavailable }
        guard (200...299).contains(response.statusCode) else { throw AgonesSDKError.rejected(statusCode: response.statusCode) }
        return response
    }
}

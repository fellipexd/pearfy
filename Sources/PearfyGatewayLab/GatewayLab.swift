import Foundation

public enum GatewayLabEnvironment: String, Sendable, Codable {
    case development
    case staging
    case production
}

public enum GatewayLabMode: String, Sendable, Codable {
    case live
    case sandbox
    case fake
}

/// Hard upper bounds keep test harnesses from retaining unbounded scenario data.
public enum GatewayLabLimits {
    public static let maximumFixtureCount = 128
    public static let maximumResponsesPerFixture = 128
    public static let maximumResponseBodyBytes = 1_048_576
    public static let maximumTotalResponseBodyBytes = 16_777_216
    public static let maximumResponseHeaderCount = 64
    public static let maximumResponseHeaderBytes = 16_384
    public static let maximumTrackedRuns = 1_024
    public static let maximumJournalEntries = 4_096
    public static let defaultTrackedRuns = 128
    public static let defaultJournalEntries = 512
}

public struct GatewayLabConfiguration: Sendable, Equatable {
    public let environment: GatewayLabEnvironment
    public let mode: GatewayLabMode
    public let endpoint: URL?

    public init(environment: GatewayLabEnvironment, mode: GatewayLabMode, endpoint: URL? = nil) {
        self.environment = environment
        self.mode = mode
        self.endpoint = endpoint
    }

    public func validate() throws {
        if environment == .production && mode == .fake { throw GatewayLabError.fakeForbiddenInProduction }
        if let endpoint {
            guard let scheme = endpoint.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = endpoint.host, !host.isEmpty,
                  endpoint.user == nil, endpoint.password == nil,
                  endpoint.query == nil, endpoint.fragment == nil else {
                throw GatewayLabError.invalidEndpoint
            }
            if mode == .fake, Self.isLiveHost(host) { throw GatewayLabError.liveEndpointInFakeMode }
            if mode == .sandbox, Self.isLiveHost(host) { throw GatewayLabError.liveEndpointInSandboxMode }
        }
    }

    private static func isLiveHost(_ host: String?) -> Bool {
        guard let host else { return false }
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let octets = normalized.split(separator: ".").compactMap { UInt8($0) }
        let isIPv4Loopback = octets.count == 4 && octets[0] == 127
        return !(["localhost", "127.0.0.1", "::1"].contains(normalized)
            || isIPv4Loopback
            || normalized.hasSuffix(".localhost")
            || normalized.hasSuffix(".test")
            || normalized.hasSuffix(".invalid"))
    }
}

public enum GatewayLabError: Error, Sendable, Equatable {
    case fakeForbiddenInProduction
    case invalidEndpoint
    case liveEndpointInFakeMode
    case liveEndpointInSandboxMode
    case noMatchingFixture
    case timeout
    case connectionReset
    case malformedResponse
    case invalidFixture
    case resourceLimitExceeded
}

public actor GatewayLabVirtualClock {
    private var instant: Duration

    public init(startingAt instant: Duration = .zero) { self.instant = instant }

    public func now() -> Duration { instant }

    public func advance(by duration: Duration) {
        guard duration > .zero else { return }
        instant += duration
    }
}

public struct GatewayLabContext: Sendable {
    public let runID: String
    public let tenantID: String
    public let seed: UInt64
    public let clock: GatewayLabVirtualClock

    public init(runID: String, tenantID: String = "default", seed: UInt64 = 0, clock: GatewayLabVirtualClock = .init()) throws {
        guard Self.isSafeIdentifier(runID), Self.isSafeIdentifier(tenantID) else { throw GatewayLabError.invalidFixture }
        self.runID = runID
        self.tenantID = tenantID
        self.seed = seed
        self.clock = clock
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

public protocol GatewayLabProvider: Sendable {
    associatedtype Request: Sendable
    associatedtype Response: Sendable
    static var providerID: String { get }
    func handle(_ request: Request, context: GatewayLabContext) async throws -> Response
}

public actor GatewayLabProviderRegistry {
    private var providers: Set<String> = []

    public init() {}

    public func register<P: GatewayLabProvider>(_ provider: P.Type) throws {
        let id = P.providerID
        guard !id.isEmpty, id.utf8.count <= 128,
              id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else {
            throw GatewayLabError.invalidFixture
        }
        providers.insert(id)
    }

    public func registeredProviderIDs() -> [String] { providers.sorted() }
}

public struct FakeHTTPRequest: Sendable, Equatable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method.uppercased()
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct FakeHTTPResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) throws {
        let headerBytes = headers.reduce(into: 0) { total, header in
            total += header.key.utf8.count + header.value.utf8.count
        }
        guard (100...599).contains(status),
              body.count <= GatewayLabLimits.maximumResponseBodyBytes,
              headers.count <= GatewayLabLimits.maximumResponseHeaderCount,
              headerBytes <= GatewayLabLimits.maximumResponseHeaderBytes else {
            throw GatewayLabError.invalidFixture
        }
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public enum FakeHTTPFault: Sendable, Equatable {
    case timeoutBeforeProcessing
    case timeoutAfterProcessing
    case connectionReset
    case malformedResponse
}

public struct FakeHTTPFixture: Sendable {
    public let method: String
    public let host: String
    public let path: String
    public let responses: [FakeHTTPResponse]
    public let faults: [FakeHTTPFault]
    public let delay: Duration

    public init(method: String, host: String, path: String, responses: [FakeHTTPResponse], faults: [FakeHTTPFault] = [], delay: Duration = .zero) throws {
        let normalizedMethod = method.uppercased()
        let validMethod = !normalizedMethod.isEmpty && normalizedMethod.utf8.allSatisfy { $0 > 32 && $0 < 127 }
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let isIPv6Literal = normalizedHost.contains(":") && normalizedHost.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0) || $0 == 58 || $0 == 46
        }
        let hostURLString = isIPv6Literal ? "http://[\(normalizedHost)]/" : "http://\(normalizedHost)/"
        let parsedHostURL = URL(string: hostURLString)
        let validHost = !normalizedHost.isEmpty && normalizedHost.utf8.count <= 253
            && normalizedHost.utf8.allSatisfy { $0 > 32 && $0 < 127 && ![47, 63, 35, 64].contains($0) }
            && (!normalizedHost.contains(":") || isIPv6Literal)
            && parsedHostURL?.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased() == normalizedHost
            && parsedHostURL?.port == nil
        let validPath = path.hasPrefix("/") && path.utf8.count <= 2_048
            && !path.contains("?") && !path.contains("#")
            && path.utf8.allSatisfy { $0 > 32 && $0 != 127 }
        guard validMethod, validHost, validPath, !responses.isEmpty,
              responses.count <= GatewayLabLimits.maximumResponsesPerFixture,
              faults.count <= GatewayLabLimits.maximumResponsesPerFixture,
              delay >= .zero else { throw GatewayLabError.invalidFixture }
        self.method = normalizedMethod
        self.host = normalizedHost
        self.path = path
        self.responses = responses
        self.faults = faults
        self.delay = delay
    }

    fileprivate func matches(_ request: FakeHTTPRequest) -> Bool {
        method == request.method && host == request.url.host?.lowercased() && path == request.url.path
    }
}

public struct GatewayLabJournalEntry: Sendable, Equatable {
    public let runID: String
    public let method: String
    public let path: String
    public let outcome: String
    public let status: Int?
}

/// Deterministic HTTP fake. It has no URLSession/live-network fallback.
public actor FakeHTTPProvider: GatewayLabProvider {
    public static let providerID = "http"

    private struct RunState {
        var responseCursors: [Int: Int] = [:]
        var faultCursors: [Int: Int] = [:]
    }

    private let fixtures: [FakeHTTPFixture]
    private let maximumTrackedRuns: Int
    private let maximumJournalEntries: Int
    private var runs: [String: RunState] = [:]
    private var journal: [GatewayLabJournalEntry] = []

    public init(
        fixtures: [FakeHTTPFixture],
        maximumTrackedRuns: Int = GatewayLabLimits.defaultTrackedRuns,
        maximumJournalEntries: Int = GatewayLabLimits.defaultJournalEntries
    ) throws {
        let fixtureKeys = fixtures.map { "\($0.method)\u{0}\($0.host)\u{0}\($0.path)" }
        let totalResponseBodyBytes = fixtures.reduce(into: 0) { total, fixture in
            total += fixture.responses.reduce(into: 0) { fixtureTotal, response in
                fixtureTotal += response.body.count
            }
        }
        guard !fixtures.isEmpty,
              fixtures.count <= GatewayLabLimits.maximumFixtureCount,
              totalResponseBodyBytes <= GatewayLabLimits.maximumTotalResponseBodyBytes,
              Set(fixtureKeys).count == fixtures.count,
              (1...GatewayLabLimits.maximumTrackedRuns).contains(maximumTrackedRuns),
              (0...GatewayLabLimits.maximumJournalEntries).contains(maximumJournalEntries) else {
            throw GatewayLabError.invalidFixture
        }
        self.fixtures = fixtures
        self.maximumTrackedRuns = maximumTrackedRuns
        self.maximumJournalEntries = maximumJournalEntries
    }

    public func send(_ request: FakeHTTPRequest, context: GatewayLabContext) async throws -> FakeHTTPResponse {
        guard let index = fixtures.firstIndex(where: { $0.matches(request) }) else {
            record(.init(runID: context.runID, method: request.method, path: "<unmatched>", outcome: "unmatched", status: nil))
            throw GatewayLabError.noMatchingFixture
        }
        let fixture = fixtures[index]
        guard runs[context.runID] != nil || runs.count < maximumTrackedRuns else {
            record(.init(runID: context.runID, method: request.method, path: fixture.path, outcome: "capacity-exceeded", status: nil))
            throw GatewayLabError.resourceLimitExceeded
        }
        if fixture.delay > .zero { await context.clock.advance(by: fixture.delay) }
        var state = runs[context.runID, default: RunState()]
        let responseCursor = state.responseCursors[index, default: 0]
        let faultCursor = state.faultCursors[index, default: 0]
        let fault = faultCursor < fixture.faults.count ? fixture.faults[faultCursor] : nil
        let response = fixture.responses[min(responseCursor, fixture.responses.count - 1)]
        if fault != nil { state.faultCursors[index] = faultCursor + 1 }

        switch fault {
        case .timeoutBeforeProcessing:
            runs[context.runID] = state
            record(.init(runID: context.runID, method: request.method, path: fixture.path, outcome: "timeout-before", status: nil))
            throw GatewayLabError.timeout
        case .timeoutAfterProcessing:
            state.responseCursors[index] = responseCursor + 1
            runs[context.runID] = state
            record(.init(runID: context.runID, method: request.method, path: fixture.path, outcome: "timeout-after", status: response.status))
            throw GatewayLabError.timeout
        case .connectionReset:
            state.responseCursors[index] = responseCursor + 1
            runs[context.runID] = state
            record(.init(runID: context.runID, method: request.method, path: fixture.path, outcome: "connection-reset", status: nil))
            throw GatewayLabError.connectionReset
        case .malformedResponse:
            state.responseCursors[index] = responseCursor + 1
            runs[context.runID] = state
            record(.init(runID: context.runID, method: request.method, path: fixture.path, outcome: "malformed", status: nil))
            throw GatewayLabError.malformedResponse
        case nil:
            state.responseCursors[index] = responseCursor + 1
            runs[context.runID] = state
            record(.init(runID: context.runID, method: request.method, path: fixture.path, outcome: "response", status: response.status))
            return response
        }
    }

    public func handle(_ request: FakeHTTPRequest, context: GatewayLabContext) async throws -> FakeHTTPResponse {
        try await send(request, context: context)
    }

    public func journalEntries(runID: String? = nil) -> [GatewayLabJournalEntry] {
        guard let runID else { return journal }
        return journal.filter { $0.runID == runID }
    }

    private func record(_ entry: GatewayLabJournalEntry) {
        guard maximumJournalEntries > 0 else { return }
        if journal.count == maximumJournalEntries { journal.removeFirst() }
        journal.append(entry)
    }

    /// Clears a run's sequence state and releases its tracked-run capacity.
    public func reset(runID: String) { runs.removeValue(forKey: runID) }
}

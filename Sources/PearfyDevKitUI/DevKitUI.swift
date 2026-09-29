import Foundation
import PearfyObservability
import PearfyWeb

public enum DevKitWindow: String, Codable, CaseIterable, Sendable {
    case fifteenMinutes = "15m"
    case oneHour = "1h"
    case twentyFourHours = "24h"
}

public enum DevKitEnvironment: String, Codable, Sendable {
    case local
    case development
    case test
    case staging
    case production
}

public struct DevKitQuery: Codable, Sendable, Equatable {
    public let window: DevKitWindow
    public let instanceID: String?

    public init(window: DevKitWindow, instanceID: String? = nil) {
        self.window = window
        self.instanceID = instanceID
    }
}

public struct DevKitConfiguration: Sendable, Equatable {
    public let enabled: Bool
    public let environment: DevKitEnvironment
    public let bearerToken: String?
    public let serviceName: String
    public let instanceID: String?

    public init(
        enabled: Bool = false,
        environment: DevKitEnvironment = .development,
        bearerToken: String? = nil,
        serviceName: String = "pearfy",
        instanceID: String? = nil
    ) {
        self.enabled = enabled
        self.environment = environment
        self.bearerToken = bearerToken
        self.serviceName = serviceName
        self.instanceID = instanceID
    }
}

public enum DevKitConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidToken
    case invalidServiceName
    case invalidInstanceID

    public var description: String {
        switch self {
        case .invalidToken:
            "PEARFY_DEVKIT_001: enabling DevKit requires a bearer token of 16–256 printable characters"
        case .invalidServiceName:
            "PEARFY_DEVKIT_002: service name must contain 1–128 printable characters"
        case .invalidInstanceID:
            "PEARFY_DEVKIT_003: instance ID must contain 1–128 ASCII letters, digits, '.', '_' or '-'"
        }
    }
}

public struct DevKitOverview: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let requestedWindow: DevKitWindow
    public let windowApplied: Bool
    public let scope: String
    public let requestCount: UInt64?
    public let errorCount: UInt64?
    public let averageLatencyMilliseconds: Double?
    public let p50Milliseconds: Double?
    public let p95Milliseconds: Double?
    public let p99Milliseconds: Double?
    public let latencyPercentilesEstimated: Bool
    public let cpuPercent: Double?
    public let memoryBytes: UInt64?
    public let storageBytes: UInt64?

    public init(
        generatedAt: Date = Date(),
        requestedWindow: DevKitWindow,
        windowApplied: Bool,
        scope: String,
        requestCount: UInt64? = nil,
        errorCount: UInt64? = nil,
        averageLatencyMilliseconds: Double? = nil,
        p50Milliseconds: Double? = nil,
        p95Milliseconds: Double? = nil,
        p99Milliseconds: Double? = nil,
        latencyPercentilesEstimated: Bool = false,
        cpuPercent: Double? = nil,
        memoryBytes: UInt64? = nil,
        storageBytes: UInt64? = nil
    ) {
        self.generatedAt = generatedAt
        self.requestedWindow = requestedWindow
        self.windowApplied = windowApplied
        self.scope = scope
        self.requestCount = requestCount
        self.errorCount = errorCount
        self.averageLatencyMilliseconds = averageLatencyMilliseconds
        self.p50Milliseconds = p50Milliseconds
        self.p95Milliseconds = p95Milliseconds
        self.p99Milliseconds = p99Milliseconds
        self.latencyPercentilesEstimated = latencyPercentilesEstimated
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.storageBytes = storageBytes
    }
}

public struct DevKitOverviewResponse: Codable, Sendable, Equatable {
    public let serviceName: String
    public let environment: DevKitEnvironment
    public let instanceID: String?
    public let availableSources: [String]
    public let overview: DevKitOverview

    public init(
        serviceName: String,
        environment: DevKitEnvironment,
        instanceID: String?,
        availableSources: [String],
        overview: DevKitOverview
    ) {
        self.serviceName = serviceName
        self.environment = environment
        self.instanceID = instanceID
        self.availableSources = availableSources.sorted()
        self.overview = overview
    }
}

public struct DevKitRouteMetrics: Codable, Sendable, Equatable {
    public let method: String
    public let pathTemplate: String
    public let scope: String
    public let requestCount: UInt64
    public let errorCount: UInt64
    public let averageLatencyMilliseconds: Double?
    public let p50Milliseconds: Double?
    public let p95Milliseconds: Double?
    public let p99Milliseconds: Double?
    public let latencyPercentilesEstimated: Bool
    public let retries: UInt64?

    public init(
        method: String,
        pathTemplate: String,
        scope: String,
        requestCount: UInt64,
        errorCount: UInt64,
        averageLatencyMilliseconds: Double? = nil,
        p50Milliseconds: Double? = nil,
        p95Milliseconds: Double? = nil,
        p99Milliseconds: Double? = nil,
        latencyPercentilesEstimated: Bool = false,
        retries: UInt64? = nil
    ) {
        self.method = method
        self.pathTemplate = pathTemplate
        self.scope = scope
        self.requestCount = requestCount
        self.errorCount = errorCount
        self.averageLatencyMilliseconds = averageLatencyMilliseconds
        self.p50Milliseconds = p50Milliseconds
        self.p95Milliseconds = p95Milliseconds
        self.p99Milliseconds = p99Milliseconds
        self.latencyPercentilesEstimated = latencyPercentilesEstimated
        self.retries = retries
    }
}

public struct DevKitRoute: Codable, Sendable, Equatable {
    public let method: String
    public let pathTemplate: String
    public let group: String?
    public let requestTypeName: String?
    public let responseTypeName: String?
    public let metrics: DevKitRouteMetrics?

    public init(
        method: String,
        pathTemplate: String,
        group: String?,
        requestTypeName: String?,
        responseTypeName: String?,
        metrics: DevKitRouteMetrics?
    ) {
        self.method = method
        self.pathTemplate = pathTemplate
        self.group = group
        self.requestTypeName = requestTypeName
        self.responseTypeName = responseTypeName
        self.metrics = metrics
    }
}

public struct DevKitSpan: Codable, Sendable, Equatable {
    public let spanID: String
    public let parentSpanID: String?
    public let name: String
    public let startedAt: Date
    public let durationMilliseconds: Double
    public let status: String

    public init(
        spanID: String,
        parentSpanID: String? = nil,
        name: String,
        startedAt: Date,
        durationMilliseconds: Double,
        status: String
    ) {
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.name = name
        self.startedAt = startedAt
        self.durationMilliseconds = durationMilliseconds
        self.status = status
    }
}

public enum DevKitTraceKind: String, Codable, Sendable {
    case request
    case work
}

public struct DevKitTrace: Codable, Sendable, Equatable {
    public let traceID: String
    public let kind: DevKitTraceKind
    public let routeTemplate: String?
    public let method: String?
    public let startedAt: Date
    public let durationMilliseconds: Double
    public let status: String
    public let spans: [DevKitSpan]
    public let statusCode: Int?

    public init(
        traceID: String,
        kind: DevKitTraceKind? = nil,
        routeTemplate: String? = nil,
        method: String? = nil,
        startedAt: Date,
        durationMilliseconds: Double,
        status: String,
        spans: [DevKitSpan] = [],
        statusCode: Int? = nil
    ) {
        self.traceID = traceID
        self.kind = kind ?? (method != nil || routeTemplate != nil ? .request : .work)
        self.routeTemplate = routeTemplate
        self.method = method
        self.startedAt = startedAt
        self.durationMilliseconds = durationMilliseconds
        self.status = status
        self.spans = spans
        self.statusCode = statusCode
    }

    private enum CodingKeys: String, CodingKey {
        case traceID
        case kind
        case routeTemplate
        case method
        case startedAt
        case durationMilliseconds
        case status
        case spans
        case statusCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        traceID = try container.decode(String.self, forKey: .traceID)
        routeTemplate = try container.decodeIfPresent(String.self, forKey: .routeTemplate)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        durationMilliseconds = try container.decode(Double.self, forKey: .durationMilliseconds)
        status = try container.decode(String.self, forKey: .status)
        spans = try container.decodeIfPresent([DevKitSpan].self, forKey: .spans) ?? []
        statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode)
        kind = try container.decodeIfPresent(DevKitTraceKind.self, forKey: .kind)
            ?? (method != nil || routeTemplate != nil ? .request : .work)
    }
}

/// A sanitized HTTP error event. Response bodies and exception messages are never included.
public struct DevKitError: Codable, Sendable, Equatable {
    public let traceID: String
    public let timestamp: Date
    public let routeTemplate: String?
    public let method: String?
    public let statusCode: Int
    public let durationMilliseconds: Double
    public let category: String

    public init(trace: DevKitTrace, statusCode: Int) {
        traceID = trace.traceID
        timestamp = trace.startedAt.addingTimeInterval(trace.durationMilliseconds / 1_000)
        routeTemplate = trace.routeTemplate
        method = trace.method
        self.statusCode = statusCode
        durationMilliseconds = trace.durationMilliseconds
        category = statusCode >= 500 ? "server" : "client"
    }
}

public struct DevKitLog: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let severity: String
    /// Providers must redact secrets and personal data before constructing a log record.
    public let message: String
    public let traceID: String?
    public let spanID: String?
    public let routeTemplate: String?

    public init(
        timestamp: Date,
        severity: String,
        message: String,
        traceID: String? = nil,
        spanID: String? = nil,
        routeTemplate: String? = nil
    ) {
        self.timestamp = timestamp
        self.severity = severity
        self.message = message
        self.traceID = traceID
        self.spanID = spanID
        self.routeTemplate = routeTemplate
    }
}

public struct DevKitInstance: Codable, Sendable, Equatable {
    public let id: String
    public let serviceName: String
    public let sampledAt: Date?
    public let cpuPercent: Double?
    public let memoryBytes: UInt64?
    public let status: String

    public init(
        id: String,
        serviceName: String,
        sampledAt: Date? = nil,
        cpuPercent: Double? = nil,
        memoryBytes: UInt64? = nil,
        status: String
    ) {
        self.id = id
        self.serviceName = serviceName
        self.sampledAt = sampledAt
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.status = status
    }
}

/// Normalized, aggregate query telemetry. No SQL statement or bind values are exposed.
public struct DevKitQueryMetrics: Codable, Sendable, Equatable {
    public let fingerprint: String
    public let routeTemplate: String?
    public let executionCount: UInt64
    public let errorCount: UInt64
    public let scope: String
    public let averageLatencyMilliseconds: Double?
    public let p95Milliseconds: Double?

    public init(
        fingerprint: String,
        routeTemplate: String? = nil,
        executionCount: UInt64,
        errorCount: UInt64 = 0,
        scope: String,
        averageLatencyMilliseconds: Double? = nil,
        p95Milliseconds: Double? = nil
    ) {
        self.fingerprint = fingerprint
        self.routeTemplate = routeTemplate
        self.executionCount = executionCount
        self.errorCount = errorCount
        self.scope = scope
        self.averageLatencyMilliseconds = averageLatencyMilliseconds
        self.p95Milliseconds = p95Milliseconds
    }
}

public struct DevKitSnapshot: Codable, Sendable, Equatable {
    public let overview: DevKitOverview
    public let routeMetrics: [DevKitRouteMetrics]
    public let traces: [DevKitTrace]
    public let logs: [DevKitLog]
    public let instances: [DevKitInstance]
    public let queries: [DevKitQueryMetrics]
    public let availableSources: [String]

    public init(
        overview: DevKitOverview,
        routeMetrics: [DevKitRouteMetrics] = [],
        traces: [DevKitTrace] = [],
        logs: [DevKitLog] = [],
        instances: [DevKitInstance] = [],
        queries: [DevKitQueryMetrics] = [],
        availableSources: [String] = []
    ) {
        self.overview = overview
        self.routeMetrics = routeMetrics
        self.traces = traces
        self.logs = logs
        self.instances = instances
        self.queries = queries
        self.availableSources = Array(Set(availableSources)).sorted()
    }
}

/// A replaceable data boundary for tracing, structured logs, and resource adapters.
public struct DevKitSnapshotSource: Sendable {
    private let readSnapshot: @Sendable (DevKitQuery) async throws -> DevKitSnapshot

    public init(snapshot: @escaping @Sendable (DevKitQuery) async throws -> DevKitSnapshot) {
        readSnapshot = snapshot
    }

    public func snapshot(for query: DevKitQuery) async throws -> DevKitSnapshot {
        try await readSnapshot(query)
    }

    /// Adapts Pearfy HTTP metrics. With an in-process telemetry store, the
    /// dashboard uses rolling windows; without one, it preserves registry scope.
    public static func httpMetrics(
        _ registry: MetricsRegistry,
        router: HTTPRouter,
        telemetry: InProcessTelemetryStore? = nil,
        instanceID: String? = nil
    ) -> Self {
        Self { query in
            let operations = try await router.contractOperations()
            if let telemetry {
                let availableInstanceID = instanceID ?? "local"
                guard query.instanceID == nil || query.instanceID == availableInstanceID else {
                    return DevKitSnapshot(
                        overview: DevKitOverview(
                            requestedWindow: query.window,
                            windowApplied: true,
                            scope: "selected instance is not available in this process"
                        ),
                        availableSources: ["http-metrics", "http-window-metrics", "route-registry", "database-query-metrics", "redacted-logs"]
                    )
                }
                let windowSeconds: TimeInterval
                switch query.window {
                case .fifteenMinutes: windowSeconds = 15 * 60
                case .oneHour: windowSeconds = 60 * 60
                case .twentyFourHours: windowSeconds = 24 * 60 * 60
                }
                let values = await telemetry.snapshot(windowSeconds: windowSeconds)
                return DevKitHTTPMetricsSnapshot.make(values, operations: operations, query: query)
            }
            let metrics = await registry.snapshot()
            return DevKitHTTPMetricsSnapshot.make(metrics, operations: operations, query: query)
        }
    }

    fileprivate static func requestTraces(
        _ store: DevKitRequestTraceStore,
        router: HTTPRouter,
        configuration: DevKitConfiguration
    ) -> Self {
        Self { query in
            let operations = try await router.contractOperations()
                .filter { !$0.path.hasPrefix(PearfyDevKitUI.routePrefix) }
            let instanceID = configuration.instanceID ?? "local"
            let matchesInstance = query.instanceID == nil || query.instanceID == instanceID
            let traces = matchesInstance ? await store.traces(in: query.window) : []
            return DevKitRequestTraceSnapshot.make(
                traces: traces,
                operations: operations,
                query: query,
                configuration: configuration
            )
        }
    }

    fileprivate func includingRequestTraces(from localSource: Self) -> Self {
        Self { query in
            let primary = try await self.snapshot(for: query)
            let local = try await localSource.snapshot(for: query)
            let traces = Self.mergeTraces(primary.traces, local.traces)
            let hasHTTPMetrics = primary.availableSources.contains("http-metrics")
            return DevKitSnapshot(
                overview: Self.mergeOverview(primary.overview, local.overview),
                routeMetrics: hasHTTPMetrics ? primary.routeMetrics : local.routeMetrics,
                traces: traces,
                logs: primary.logs,
                instances: primary.instances.isEmpty ? local.instances : primary.instances,
                queries: primary.queries,
                availableSources: primary.availableSources + local.availableSources
            )
        }
    }

    public static func empty() -> Self {
        Self { query in
            DevKitSnapshot(
                overview: DevKitOverview(
                    requestedWindow: query.window,
                    windowApplied: false,
                    scope: "no telemetry source configured"
                ),
                availableSources: ["route-registry"]
            )
        }
    }

    private static func mergeTraces(_ primary: [DevKitTrace], _ local: [DevKitTrace]) -> [DevKitTrace] {
        var identifiers: Set<String> = []
        var merged: [DevKitTrace] = []
        for trace in (primary + local).sorted(by: { $0.startedAt > $1.startedAt }) {
            guard identifiers.insert(trace.traceID).inserted else { continue }
            merged.append(trace)
            if merged.count == DevKitRequestTraceStore.capacity { break }
        }
        return merged
    }

    private static func mergeOverview(
        _ primary: DevKitOverview,
        _ local: DevKitOverview
    ) -> DevKitOverview {
        let primaryHasRequestMetrics = primary.requestCount != nil || primary.errorCount != nil
            || primary.averageLatencyMilliseconds != nil || primary.p50Milliseconds != nil
            || primary.p95Milliseconds != nil || primary.p99Milliseconds != nil
        let primaryHasLatency = primary.averageLatencyMilliseconds != nil || primary.p50Milliseconds != nil
            || primary.p95Milliseconds != nil || primary.p99Milliseconds != nil
        let scope = primaryHasRequestMetrics ? primary.scope : local.scope
        return DevKitOverview(
            generatedAt: max(primary.generatedAt, local.generatedAt),
            requestedWindow: local.requestedWindow,
            windowApplied: primaryHasRequestMetrics ? primary.windowApplied && local.windowApplied : local.windowApplied,
            scope: scope,
            requestCount: primary.requestCount ?? local.requestCount,
            errorCount: primary.errorCount ?? local.errorCount,
            averageLatencyMilliseconds: primary.averageLatencyMilliseconds ?? local.averageLatencyMilliseconds,
            p50Milliseconds: primary.p50Milliseconds ?? local.p50Milliseconds,
            p95Milliseconds: primary.p95Milliseconds ?? local.p95Milliseconds,
            p99Milliseconds: primary.p99Milliseconds ?? local.p99Milliseconds,
            latencyPercentilesEstimated: primaryHasLatency
                ? primary.latencyPercentilesEstimated
                : local.latencyPercentilesEstimated,
            cpuPercent: primary.cpuPercent,
            memoryBytes: primary.memoryBytes,
            storageBytes: primary.storageBytes
        )
    }
}

private enum DevKitRequestTraceSnapshot {
    static func make(
        traces: [DevKitTrace],
        operations: [HTTPRouteContractOperation],
        query: DevKitQuery,
        configuration: DevKitConfiguration
    ) -> DevKitSnapshot {
        let durations = traces.map(\.durationMilliseconds)
        let errors = traces.filter { ($0.statusCode ?? 0) >= 400 && ($0.statusCode ?? 0) <= 599 }
        let totalDuration = durations.reduce(0, +)
        let overview = DevKitOverview(
            requestedWindow: query.window,
            windowApplied: true,
            scope: "in-process recent sample (up to \(DevKitRequestTraceStore.capacity) requests)",
            requestCount: UInt64(traces.count),
            errorCount: UInt64(errors.count),
            averageLatencyMilliseconds: durations.isEmpty ? nil : totalDuration / Double(durations.count),
            p50Milliseconds: percentile(0.50, values: durations),
            p95Milliseconds: percentile(0.95, values: durations),
            p99Milliseconds: percentile(0.99, values: durations),
            latencyPercentilesEstimated: false
        )
        let routeMetrics = operations.map { operation -> DevKitRouteMetrics in
            let method = operation.method.description
            let routeTraces = traces.filter {
                $0.method?.caseInsensitiveCompare(method) == .orderedSame
                    && $0.routeTemplate == operation.path
            }
            let routeDurations = routeTraces.map(\.durationMilliseconds)
            let routeErrorCount = routeTraces.filter { ($0.statusCode ?? 0) >= 400 && ($0.statusCode ?? 0) <= 599 }.count
            return DevKitRouteMetrics(
                method: method,
                pathTemplate: operation.path,
                scope: "in-process recent trace sample",
                requestCount: UInt64(routeTraces.count),
                errorCount: UInt64(routeErrorCount),
                averageLatencyMilliseconds: routeDurations.isEmpty
                    ? nil
                    : routeDurations.reduce(0, +) / Double(routeDurations.count),
                p50Milliseconds: percentile(0.50, values: routeDurations),
                p95Milliseconds: percentile(0.95, values: routeDurations),
                p99Milliseconds: percentile(0.99, values: routeDurations)
            )
        }
        let instances = [DevKitInstance(
            id: configuration.instanceID ?? "local",
            serviceName: configuration.serviceName,
            status: "local"
        )]
        return DevKitSnapshot(
            overview: overview,
            routeMetrics: routeMetrics,
            traces: traces,
            instances: instances,
            availableSources: ["request-errors", "request-traces", "route-registry"]
        )
    }

    private static func percentile(_ quantile: Double, values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * quantile)) - 1))
        return sorted[index]
    }
}

public enum PearfyDevKitUI {
    public static let routePrefix = "/__pearfy/devkit"
    private static let apiPrefix = "\(routePrefix)/api"

    /// Installs a bearer-protected, read-only dashboard in the application's
    /// router. It is opt-in and requires an explicit local token in every
    /// environment; production remains disabled unless called deliberately.
    public static func install(
        on router: HTTPRouter,
        configuration: DevKitConfiguration = DevKitConfiguration(),
        source: DevKitSnapshotSource? = nil
    ) async throws {
        guard configuration.enabled else { return }
        try validate(configuration)
        let traceStore = DevKitRequestTraceStore()
        let localSource = DevKitSnapshotSource.requestTraces(
            traceStore,
            router: router,
            configuration: configuration
        )
        let handler = DevKitRequestHandler(
            router: router,
            configuration: configuration,
            source: source?.includingRequestTraces(from: localSource) ?? localSource,
            fallbackSource: localSource
        )

        try await router.get(routePrefix) { _ in
            Self.asset("devkit", extension: "html", contentType: "text/html; charset=utf-8")
        }
        try await router.get("\(routePrefix)/assets/devkit.js") { _ in
            Self.asset("devkit", extension: "js", contentType: "text/javascript; charset=utf-8")
        }
        try await router.get("\(routePrefix)/assets/devkit.css") { _ in
            Self.asset("devkit", extension: "css", contentType: "text/css; charset=utf-8")
        }
        try await router.get("\(routePrefix)/assets/traces.css") { _ in
            Self.asset("traces", extension: "css", contentType: "text/css; charset=utf-8")
        }
        try await router.get("\(apiPrefix)/overview") { request in
            await handler.handle(.overview, request: request)
        }
        try await router.get("\(apiPrefix)/routes") { request in
            await handler.handle(.routes, request: request)
        }
        try await router.get("\(apiPrefix)/traces") { request in
            await handler.handle(.traces, request: request)
        }
        try await router.get("\(apiPrefix)/errors") { request in
            await handler.handle(.errors, request: request)
        }
        try await router.get("\(apiPrefix)/logs") { request in
            await handler.handle(.logs, request: request)
        }
        try await router.get("\(apiPrefix)/instances") { request in
            await handler.handle(.instances, request: request)
        }
        try await router.get("\(apiPrefix)/queries") { request in
            await handler.handle(.queries, request: request)
        }
        try await router.useFirst(await traceStore.middleware())
    }

    static func validate(_ configuration: DevKitConfiguration) throws {
        guard let token = configuration.bearerToken,
              (16...256).contains(token.utf8.count),
              token.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else {
            throw DevKitConfigurationError.invalidToken
        }
        guard !configuration.serviceName.isEmpty,
              configuration.serviceName.utf8.count <= 128,
              configuration.serviceName.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7e }) else {
            throw DevKitConfigurationError.invalidServiceName
        }
        if let id = configuration.instanceID {
            guard !id.isEmpty,
                  id.utf8.count <= 128,
                  id.utf8.allSatisfy({
                      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
                  }) else {
                throw DevKitConfigurationError.invalidInstanceID
            }
        }
    }

    private static func asset(_ name: String, extension fileExtension: String, contentType: String) -> HTTPResponse {
        guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension),
              let data = try? Data(contentsOf: url) else {
            return HTTPResponse.text("Not Found", status: HTTPStatus.notFound.rawValue)
        }
        var headers = ["content-type": contentType, "cache-control": "no-store", "x-content-type-options": "nosniff"]
        if fileExtension == "html" {
            headers["content-security-policy"] = "default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
            headers["referrer-policy"] = "no-referrer"
        }
        return HTTPResponse(headers: headers, body: data)
    }
}

private enum DevKitEndpoint: Equatable {
    case overview
    case routes
    case traces
    case errors
    case logs
    case instances
    case queries
}

private struct DevKitRequestHandler: Sendable {
    let router: HTTPRouter
    let configuration: DevKitConfiguration
    let source: DevKitSnapshotSource
    let fallbackSource: DevKitSnapshotSource

    func handle(_ endpoint: DevKitEndpoint, request: HTTPRequest) async -> HTTPResponse {
        guard Self.isAuthorized(request.headers["authorization"], expected: configuration.bearerToken ?? "") else {
            return HTTPResponse.text("Unauthorized", status: HTTPStatus.unauthorized.rawValue)
        }
        guard let query = Self.query(from: request) else {
            return HTTPResponse.text("Invalid DevKit query", status: HTTPStatus.badRequest.rawValue)
        }

        do {
            let snapshot: DevKitSnapshot
            do {
                snapshot = try await source.snapshot(for: query)
            } catch {
                guard endpoint == .routes || endpoint == .traces || endpoint == .errors else {
                    return HTTPResponse.text("DevKit data source unavailable", status: HTTPStatus.serviceUnavailable.rawValue)
                }
                do {
                    snapshot = try await fallbackSource.snapshot(for: query)
                } catch {
                    return HTTPResponse.text("DevKit data source unavailable", status: HTTPStatus.serviceUnavailable.rawValue)
                }
            }
            switch endpoint {
            case .overview:
                return try Self.json(DevKitOverviewResponse(
                    serviceName: configuration.serviceName,
                    environment: configuration.environment,
                    instanceID: query.instanceID ?? configuration.instanceID ?? snapshot.instances.first?.id,
                    availableSources: snapshot.availableSources,
                    overview: snapshot.overview
                ))
            case .routes:
                let operations = try await router.contractOperations()
                    .filter { !$0.path.hasPrefix(PearfyDevKitUI.routePrefix) }
                var routeKeys: Set<String> = []
                let metricIndex = Dictionary(
                    snapshot.routeMetrics.map { ("\($0.method.uppercased()) \($0.pathTemplate)", $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let routes = operations.compactMap { operation -> DevKitRoute? in
                    let key = "\(operation.method.description.uppercased()) \(operation.path)"
                    guard routeKeys.insert(key).inserted else { return nil }
                    return DevKitRoute(
                        method: operation.method.description,
                        pathTemplate: operation.path,
                        group: operation.group,
                        requestTypeName: operation.requestTypeName,
                        responseTypeName: operation.responseTypeName,
                        metrics: metricIndex[key]
                    )
                }
                return try Self.json(routes)
            case .traces:
                return try Self.json(snapshot.traces)
            case .errors:
                let errors = snapshot.traces.compactMap { trace -> DevKitError? in
                    guard let statusCode = trace.statusCode, (400...599).contains(statusCode) else { return nil }
                    return DevKitError(trace: trace, statusCode: statusCode)
                }
                return try Self.json(errors)
            case .logs:
                return try Self.json(snapshot.logs)
            case .instances:
                return try Self.json(snapshot.instances)
            case .queries:
                return try Self.json(snapshot.queries)
            }
        } catch {
            // Do not leak provider errors, SQL, credentials, or stack traces to the dashboard.
            return HTTPResponse.text("DevKit data source unavailable", status: HTTPStatus.serviceUnavailable.rawValue)
        }
    }

    private static func query(from request: HTTPRequest) -> DevKitQuery? {
        let window = request.queryValue("window").flatMap(DevKitWindow.init(rawValue:)) ?? .fifteenMinutes
        if let rawWindow = request.queryValue("window"), DevKitWindow(rawValue: rawWindow) == nil { return nil }
        let instanceID = request.queryValue("instance")
        if let instanceID {
            guard !instanceID.isEmpty,
                  instanceID.utf8.count <= 128,
                  instanceID.utf8.allSatisfy({
                      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
                  }) else { return nil }
        }
        return DevKitQuery(window: window, instanceID: instanceID)
    }

    private static func isAuthorized(_ header: String?, expected: String) -> Bool {
        guard let header else { return false }
        let components = header.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard components.count == 2,
              components[0].caseInsensitiveCompare("Bearer") == .orderedSame else { return false }
        let candidate = Array(components[1].utf8)
        let expectedBytes = Array(expected.utf8)
        var difference = candidate.count == expectedBytes.count ? 0 : 1
        for index in 0..<max(candidate.count, expectedBytes.count) {
            let left = index < candidate.count ? candidate[index] : 0
            let right = index < expectedBytes.count ? expectedBytes[index] : 0
            difference |= Int(left ^ right)
        }
        return difference == 0
    }

    private static func json<Value: Encodable>(_ value: Value) throws -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= 1_048_576 else { throw HTTPError.internalServerError }
        return HTTPResponse(
            headers: ["content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff"],
            body: data
        )
    }
}

private enum DevKitHTTPMetricsSnapshot {
    private struct Accumulator {
        var requests: UInt64 = 0
        var errors: UInt64 = 0
        var histogramCount: UInt64 = 0
        var histogramSum = 0.0
        var bounds: [Double] = []
        var buckets: [UInt64] = []
    }

    static func make(
        _ telemetry: InProcessTelemetrySnapshot,
        operations: [HTTPRouteContractOperation],
        query: DevKitQuery
    ) -> DevKitSnapshot {
        let observed = Dictionary(
            telemetry.routeMetrics.map { ("\($0.method.uppercased()) \($0.routeTemplate)", $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var routeKeys: Set<String> = []
        let routeMetrics = operations
            .filter { !$0.path.hasPrefix(PearfyDevKitUI.routePrefix) }
            .compactMap { operation -> DevKitRouteMetrics? in
                let method = operation.method.description.uppercased()
                let key = "\(method) \(operation.path)"
                guard routeKeys.insert(key).inserted else { return nil }
                guard let value = observed[key] else {
                    return DevKitRouteMetrics(
                        method: method,
                        pathTemplate: operation.path,
                        scope: telemetry.scope,
                        requestCount: 0,
                        errorCount: 0
                    )
                }
                return DevKitRouteMetrics(
                    method: method,
                    pathTemplate: operation.path,
                    scope: telemetry.scope,
                    requestCount: value.requestCount,
                    errorCount: value.errorCount,
                    averageLatencyMilliseconds: value.averageLatencyMilliseconds,
                    p50Milliseconds: value.p50Milliseconds,
                    p95Milliseconds: value.p95Milliseconds,
                    p99Milliseconds: value.p99Milliseconds,
                    latencyPercentilesEstimated: value.requestCount > 0
                )
            }
        let scope: String
        if telemetry.droppedRouteEvents > 0 || telemetry.droppedQueryExecutions > 0 {
            scope = "\(telemetry.scope); cardinality caps reached (route events dropped: \(telemetry.droppedRouteEvents), query executions dropped: \(telemetry.droppedQueryExecutions))"
        } else {
            scope = telemetry.scope
        }
        let queries = telemetry.queryMetrics.map {
            DevKitQueryMetrics(
                fingerprint: $0.fingerprint,
                routeTemplate: $0.routeTemplate,
                executionCount: $0.executionCount,
                errorCount: $0.errorCount,
                scope: scope,
                averageLatencyMilliseconds: $0.averageLatencyMilliseconds,
                p95Milliseconds: $0.p95Milliseconds
            )
        }
        let logs = telemetry.logs.map {
            DevKitLog(
                timestamp: $0.timestamp,
                severity: $0.severity,
                message: $0.message,
                traceID: $0.traceID,
                routeTemplate: $0.routeTemplate
            )
        }
        return DevKitSnapshot(
            overview: DevKitOverview(
                requestedWindow: query.window,
                windowApplied: true,
                scope: scope,
                requestCount: telemetry.requestCount,
                errorCount: telemetry.errorCount,
                averageLatencyMilliseconds: telemetry.averageLatencyMilliseconds,
                p50Milliseconds: telemetry.p50Milliseconds,
                p95Milliseconds: telemetry.p95Milliseconds,
                p99Milliseconds: telemetry.p99Milliseconds,
                latencyPercentilesEstimated: telemetry.requestCount > 0
            ),
            routeMetrics: routeMetrics,
            logs: logs,
            queries: queries,
            availableSources: [
                "http-metrics",
                "http-window-metrics",
                "database-query-metrics",
                "redacted-logs",
                "route-registry"
            ]
        )
    }

    static func make(
        _ series: [MetricSeriesSnapshot],
        operations: [HTTPRouteContractOperation],
        query: DevKitQuery
    ) -> DevKitSnapshot {
        let registered = Set(operations
            .filter { !$0.path.hasPrefix(PearfyDevKitUI.routePrefix) }
            .map { "\($0.method.description) \($0.path)" })
        var values: [String: Accumulator] = [:]
        for point in series {
            guard let method = point.labels["method"]?.uppercased(),
                  let path = point.labels["route"],
                  registered.contains("\(method) \(path)") else { continue }
            let key = "\(method) \(path)"
            var value = values[key, default: Accumulator()]
            if point.name == "pearfy_http_requests_total", point.kind == .counter,
               let count = point.counterValue {
                value.requests += count
                if point.labels["status_class"] != "2xx" { value.errors += count }
            } else if point.name == "pearfy_http_request_duration_seconds",
                      point.kind == .histogram,
                      let histogram = point.histogram {
                value.histogramCount += histogram.count
                value.histogramSum += histogram.sum
                if value.bounds.isEmpty {
                    value.bounds = histogram.upperBounds
                    value.buckets = Array(repeating: 0, count: histogram.cumulativeCounts.count)
                }
                guard value.buckets.count == histogram.cumulativeCounts.count else { continue }
                for index in value.buckets.indices {
                    value.buckets[index] += histogram.cumulativeCounts[index]
                }
            }
            values[key] = value
        }

        let routeMetrics = values.keys.sorted().compactMap { key -> DevKitRouteMetrics? in
            guard let value = values[key] else { return nil }
            let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, value.requests > 0 else { return nil }
            let mean = value.histogramCount > 0 ? value.histogramSum / Double(value.histogramCount) * 1_000 : nil
            return DevKitRouteMetrics(
                method: parts[0],
                pathTemplate: parts[1],
                scope: "process-lifetime",
                requestCount: value.requests,
                errorCount: value.errors,
                averageLatencyMilliseconds: mean,
                p50Milliseconds: percentile(0.50, accumulator: value),
                p95Milliseconds: percentile(0.95, accumulator: value),
                p99Milliseconds: percentile(0.99, accumulator: value),
                latencyPercentilesEstimated: value.histogramCount > 0
            )
        }
        let requests = routeMetrics.reduce(UInt64(0)) { $0 + $1.requestCount }
        let errors = routeMetrics.reduce(UInt64(0)) { $0 + $1.errorCount }
        let totalHistogramCount = values.values.reduce(UInt64(0)) { $0 + $1.histogramCount }
        let totalHistogramSum = values.values.reduce(0.0) { $0 + $1.histogramSum }
        let combined = combine(values.values)
        let instanceFilterSupported = query.instanceID == nil
        let overview = DevKitOverview(
            requestedWindow: query.window,
            windowApplied: false,
            scope: instanceFilterSupported ? "process-lifetime" : "instance filter unavailable in HTTP metrics",
            requestCount: instanceFilterSupported ? requests : nil,
            errorCount: instanceFilterSupported ? errors : nil,
            averageLatencyMilliseconds: instanceFilterSupported && totalHistogramCount > 0
                ? totalHistogramSum / Double(totalHistogramCount) * 1_000 : nil,
            p50Milliseconds: instanceFilterSupported ? percentile(0.50, accumulator: combined) : nil,
            p95Milliseconds: instanceFilterSupported ? percentile(0.95, accumulator: combined) : nil,
            p99Milliseconds: instanceFilterSupported ? percentile(0.99, accumulator: combined) : nil,
            latencyPercentilesEstimated: true
        )
        return DevKitSnapshot(
            overview: overview,
            routeMetrics: instanceFilterSupported ? routeMetrics : [],
            availableSources: ["http-metrics", "route-registry"]
        )
    }

    private static func combine<S: Sequence>(_ values: S) -> Accumulator where S.Element == Accumulator {
        var result = Accumulator()
        for value in values {
            result.histogramCount += value.histogramCount
            result.histogramSum += value.histogramSum
            if result.bounds.isEmpty {
                result.bounds = value.bounds
                result.buckets = Array(repeating: 0, count: value.buckets.count)
            }
            guard result.buckets.count == value.buckets.count else { continue }
            for index in result.buckets.indices { result.buckets[index] += value.buckets[index] }
        }
        return result
    }

    private static func percentile(_ quantile: Double, accumulator: Accumulator) -> Double? {
        guard accumulator.histogramCount > 0,
              accumulator.bounds.count == accumulator.buckets.count else { return nil }
        let target = UInt64(ceil(Double(accumulator.histogramCount) * quantile))
        guard let index = accumulator.buckets.firstIndex(where: { $0 >= target }),
              accumulator.bounds[index].isFinite else { return nil }
        return accumulator.bounds[index] * 1_000
    }
}

import Crypto
import Foundation

public struct InProcessHTTPRouteMetrics: Sendable, Equatable {
    public let method: String
    public let routeTemplate: String
    public let requestCount: UInt64
    public let errorCount: UInt64
    public let averageLatencyMilliseconds: Double?
    public let p50Milliseconds: Double?
    public let p95Milliseconds: Double?
    public let p99Milliseconds: Double?

    public init(
        method: String,
        routeTemplate: String,
        requestCount: UInt64,
        errorCount: UInt64,
        averageLatencyMilliseconds: Double?,
        p50Milliseconds: Double?,
        p95Milliseconds: Double?,
        p99Milliseconds: Double?
    ) {
        self.method = method
        self.routeTemplate = routeTemplate
        self.requestCount = requestCount
        self.errorCount = errorCount
        self.averageLatencyMilliseconds = averageLatencyMilliseconds
        self.p50Milliseconds = p50Milliseconds
        self.p95Milliseconds = p95Milliseconds
        self.p99Milliseconds = p99Milliseconds
    }
}

public struct InProcessDatabaseQueryMetrics: Sendable, Equatable {
    /// An opaque, process-keyed fingerprint. It cannot be used to recover SQL.
    public let fingerprint: String
    public let routeTemplate: String?
    public let executionCount: UInt64
    public let errorCount: UInt64
    public let averageLatencyMilliseconds: Double?
    public let p95Milliseconds: Double?

    public init(
        fingerprint: String,
        routeTemplate: String? = nil,
        executionCount: UInt64,
        errorCount: UInt64,
        averageLatencyMilliseconds: Double?,
        p95Milliseconds: Double?
    ) {
        self.fingerprint = fingerprint
        self.routeTemplate = routeTemplate
        self.executionCount = executionCount
        self.errorCount = errorCount
        self.averageLatencyMilliseconds = averageLatencyMilliseconds
        self.p95Milliseconds = p95Milliseconds
    }
}

public struct InProcessTelemetryLog: Sendable, Equatable {
    public let timestamp: Date
    public let severity: String
    public let message: String
    public let traceID: String?
    public let routeTemplate: String?

    public init(
        timestamp: Date,
        severity: String,
        message: String,
        traceID: String? = nil,
        routeTemplate: String? = nil
    ) {
        self.timestamp = timestamp
        self.severity = severity
        self.message = message
        self.traceID = traceID
        self.routeTemplate = routeTemplate
    }
}

public struct InProcessTelemetrySnapshot: Sendable, Equatable {
    public let requestCount: UInt64
    public let errorCount: UInt64
    public let averageLatencyMilliseconds: Double?
    public let p50Milliseconds: Double?
    public let p95Milliseconds: Double?
    public let p99Milliseconds: Double?
    public let routeMetrics: [InProcessHTTPRouteMetrics]
    public let queryMetrics: [InProcessDatabaseQueryMetrics]
    public let logs: [InProcessTelemetryLog]
    public let droppedRouteEvents: UInt64
    public let droppedQueryExecutions: UInt64
    public let scope: String

    public init(
        requestCount: UInt64,
        errorCount: UInt64,
        averageLatencyMilliseconds: Double?,
        p50Milliseconds: Double?,
        p95Milliseconds: Double?,
        p99Milliseconds: Double?,
        routeMetrics: [InProcessHTTPRouteMetrics],
        queryMetrics: [InProcessDatabaseQueryMetrics],
        logs: [InProcessTelemetryLog],
        droppedRouteEvents: UInt64,
        droppedQueryExecutions: UInt64,
        scope: String
    ) {
        self.requestCount = requestCount
        self.errorCount = errorCount
        self.averageLatencyMilliseconds = averageLatencyMilliseconds
        self.p50Milliseconds = p50Milliseconds
        self.p95Milliseconds = p95Milliseconds
        self.p99Milliseconds = p99Milliseconds
        self.routeMetrics = routeMetrics
        self.queryMetrics = queryMetrics
        self.logs = logs
        self.droppedRouteEvents = droppedRouteEvents
        self.droppedQueryExecutions = droppedQueryExecutions
        self.scope = scope
    }
}

/// Request-safe context propagated through async handler work to storage adapters.
public enum TelemetryTaskContext {
    @TaskLocal public static var routeTemplate: String?
    @TaskLocal public static var traceID: String?
}

/// Bounded in-process telemetry with rolling minute buckets and redacted event logs.
public actor InProcessTelemetryStore {
    private struct HTTPKey: Hashable {
        let method: String
        let route: String
    }

    private struct QueryKey: Hashable {
        let fingerprint: String
        let route: String?
    }

    private struct Aggregate: Sendable {
        var count: UInt64 = 0
        var errors: UInt64 = 0
        var sumSeconds = 0.0
        var maximumSeconds = 0.0
        var cumulativeBuckets = Array(repeating: UInt64(0), count: Self.latencyBounds.count + 1)

        static let latencyBounds = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]

        mutating func observe(seconds: Double, failed: Bool) {
            count = incremented(count)
            if failed { errors = incremented(errors) }
            sumSeconds += seconds
            maximumSeconds = max(maximumSeconds, seconds)
            for index in Self.latencyBounds.indices where seconds <= Self.latencyBounds[index] {
                cumulativeBuckets[index] = incremented(cumulativeBuckets[index])
            }
            cumulativeBuckets[cumulativeBuckets.count - 1] = incremented(cumulativeBuckets[cumulativeBuckets.count - 1])
        }

        mutating func merge(_ other: Aggregate) {
            count = saturatedAdd(count, other.count)
            errors = saturatedAdd(errors, other.errors)
            sumSeconds += other.sumSeconds
            maximumSeconds = max(maximumSeconds, other.maximumSeconds)
            for index in cumulativeBuckets.indices {
                cumulativeBuckets[index] = saturatedAdd(cumulativeBuckets[index], other.cumulativeBuckets[index])
            }
        }

        var averageMilliseconds: Double? {
            count == 0 ? nil : sumSeconds / Double(count) * 1_000
        }

        func percentile(_ quantile: Double) -> Double? {
            guard count > 0 else { return nil }
            let target = max(UInt64(1), UInt64(ceil(Double(count) * quantile)))
            for index in cumulativeBuckets.indices where cumulativeBuckets[index] >= target {
                let seconds = index < Self.latencyBounds.count ? Self.latencyBounds[index] : maximumSeconds
                return seconds * 1_000
            }
            return maximumSeconds * 1_000
        }
    }

    private static let maximumHTTPSeries = 256
    private static let maximumQuerySeries = 512
    private static let maximumLogEvents = 1_000
    private static let retentionMinutes = 24 * 60
    private static let minuteSeconds: TimeInterval = 60

    private let fingerprintKey: SymmetricKey
    private var httpBuckets: [Int: [HTTPKey: Aggregate]] = [:]
    private var queryBuckets: [Int: [QueryKey: Aggregate]] = [:]
    private var knownHTTPSeries: Set<HTTPKey> = []
    private var knownQuerySeries: Set<QueryKey> = []
    private var logEvents: [InProcessTelemetryLog] = []
    private var droppedRouteEvents: UInt64 = 0
    private var droppedQueryExecutions: UInt64 = 0

    public init() {
        var generator = SystemRandomNumberGenerator()
        let keyBytes = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
        fingerprintKey = SymmetricKey(data: keyBytes)
    }

    /// Fingerprints are stable only for this store's lifetime and are never derived from bind values.
    public func fingerprint(forSQL statement: String) -> String {
        var authenticator = HMAC<SHA256>(key: fingerprintKey)
        var chunk = Data()
        chunk.reserveCapacity(16_384)
        for byte in statement.utf8 {
            chunk.append(byte)
            if chunk.count == 16_384 {
                authenticator.update(data: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { authenticator.update(data: chunk) }
        let digest = authenticator.finalize()
        let suffix = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "query-\(suffix)"
    }

    public func recordHTTP(
        method: String,
        routeTemplate: String?,
        traceID: String? = nil,
        statusCode: Int,
        durationMilliseconds: Double,
        timestamp: Date = Date()
    ) {
        guard durationMilliseconds.isFinite, durationMilliseconds >= 0 else { return }
        let method = safeMethod(method)
        let route = safeRouteTemplate(routeTemplate)
        let key = HTTPKey(method: method, route: route)
        guard knownHTTPSeries.contains(key) || knownHTTPSeries.count < Self.maximumHTTPSeries else {
            droppedRouteEvents = incremented(droppedRouteEvents)
            return
        }
        knownHTTPSeries.insert(key)
        let minute = minuteKey(timestamp)
        var values = httpBuckets[minute, default: [:]]
        var aggregate = values[key, default: Aggregate()]
        aggregate.observe(seconds: durationMilliseconds / 1_000, failed: statusCode >= 400)
        values[key] = aggregate
        httpBuckets[minute] = values
        prune(around: timestamp)

        if statusCode >= 400 {
            appendLog(InProcessTelemetryLog(
                timestamp: timestamp,
                severity: statusCode >= 500 ? "error" : "warning",
                message: "HTTP request completed with status \(statusCode)",
                traceID: safeTraceID(traceID),
                routeTemplate: route == "unmatched" ? nil : route
            ))
        }
    }

    public func recordDatabaseQuery(
        fingerprint: String,
        routeTemplate: String? = nil,
        traceID: String? = nil,
        durationMilliseconds: Double,
        failed: Bool,
        timestamp: Date = Date()
    ) {
        guard durationMilliseconds.isFinite, durationMilliseconds >= 0,
              fingerprint.hasPrefix("query-"), fingerprint.utf8.count <= 64 else { return }
        let route = routeTemplate.map(safeRouteTemplate).flatMap { $0 == "unmatched" ? nil : $0 }
        let key = QueryKey(fingerprint: fingerprint, route: route)
        guard knownQuerySeries.contains(key) || knownQuerySeries.count < Self.maximumQuerySeries else {
            droppedQueryExecutions = incremented(droppedQueryExecutions)
            return
        }
        knownQuerySeries.insert(key)
        let minute = minuteKey(timestamp)
        var values = queryBuckets[minute, default: [:]]
        var aggregate = values[key, default: Aggregate()]
        aggregate.observe(seconds: durationMilliseconds / 1_000, failed: failed)
        values[key] = aggregate
        queryBuckets[minute] = values
        prune(around: timestamp)

        if failed {
            appendLog(InProcessTelemetryLog(
                timestamp: timestamp,
                severity: "error",
                message: "PostgreSQL query failed",
                traceID: safeTraceID(traceID),
                routeTemplate: route
            ))
        }
    }

    public func snapshot(windowSeconds: TimeInterval, now: Date = Date()) -> InProcessTelemetrySnapshot {
        let boundedWindow = min(max(windowSeconds, 60), TimeInterval(Self.retentionMinutes) * Self.minuteSeconds)
        let firstMinute = minuteKey(now.addingTimeInterval(-boundedWindow))
        let lastMinute = minuteKey(now)
        prune(around: now)

        var routeAggregates: [HTTPKey: Aggregate] = [:]
        for minute in firstMinute...lastMinute {
            for (key, aggregate) in httpBuckets[minute, default: [:]] {
                routeAggregates[key, default: Aggregate()].merge(aggregate)
            }
        }
        var queryAggregates: [QueryKey: Aggregate] = [:]
        for minute in firstMinute...lastMinute {
            for (key, aggregate) in queryBuckets[minute, default: [:]] {
                queryAggregates[key, default: Aggregate()].merge(aggregate)
            }
        }

        var total = Aggregate()
        for aggregate in routeAggregates.values { total.merge(aggregate) }
        let routeMetrics = routeAggregates.keys.sorted {
            ($0.method + " " + $0.route) < ($1.method + " " + $1.route)
        }.compactMap { key -> InProcessHTTPRouteMetrics? in
            guard let aggregate = routeAggregates[key] else { return nil }
            return InProcessHTTPRouteMetrics(
                method: key.method,
                routeTemplate: key.route,
                requestCount: aggregate.count,
                errorCount: aggregate.errors,
                averageLatencyMilliseconds: aggregate.averageMilliseconds,
                p50Milliseconds: aggregate.percentile(0.50),
                p95Milliseconds: aggregate.percentile(0.95),
                p99Milliseconds: aggregate.percentile(0.99)
            )
        }
        let queryMetrics = queryAggregates.keys.sorted {
            ($0.fingerprint + ($0.route ?? "")) < ($1.fingerprint + ($1.route ?? ""))
        }.compactMap { key -> InProcessDatabaseQueryMetrics? in
            guard let aggregate = queryAggregates[key] else { return nil }
            return InProcessDatabaseQueryMetrics(
                fingerprint: key.fingerprint,
                routeTemplate: key.route,
                executionCount: aggregate.count,
                errorCount: aggregate.errors,
                averageLatencyMilliseconds: aggregate.averageMilliseconds,
                p95Milliseconds: aggregate.percentile(0.95)
            )
        }
        let cutoff = now.addingTimeInterval(-boundedWindow)
        let logs = logEvents
            .filter { $0.timestamp >= cutoff && $0.timestamp <= now }
            .sorted { $0.timestamp > $1.timestamp }

        return InProcessTelemetrySnapshot(
            requestCount: total.count,
            errorCount: total.errors,
            averageLatencyMilliseconds: total.averageMilliseconds,
            p50Milliseconds: total.percentile(0.50),
            p95Milliseconds: total.percentile(0.95),
            p99Milliseconds: total.percentile(0.99),
            routeMetrics: routeMetrics,
            queryMetrics: queryMetrics,
            logs: logs,
            droppedRouteEvents: droppedRouteEvents,
            droppedQueryExecutions: droppedQueryExecutions,
            scope: "in-process rolling 1-minute buckets; 24-hour retention"
        )
    }

    private func appendLog(_ event: InProcessTelemetryLog) {
        logEvents.append(event)
        if logEvents.count > Self.maximumLogEvents {
            logEvents.removeFirst(logEvents.count - Self.maximumLogEvents)
        }
    }

    private func prune(around date: Date) {
        let oldestMinute = minuteKey(date) - Self.retentionMinutes
        httpBuckets = httpBuckets.filter { $0.key >= oldestMinute }
        queryBuckets = queryBuckets.filter { $0.key >= oldestMinute }
        let oldestDate = date.addingTimeInterval(-TimeInterval(Self.retentionMinutes) * Self.minuteSeconds)
        logEvents.removeAll { $0.timestamp < oldestDate }
    }

    private func minuteKey(_ date: Date) -> Int {
        Int(floor(date.timeIntervalSince1970 / Self.minuteSeconds))
    }

    private func safeMethod(_ value: String) -> String {
        let method = value.uppercased()
        guard !method.isEmpty, method.utf8.count <= 16,
              method.utf8.allSatisfy({ (65...90).contains($0) || $0 == 45 }) else { return "OTHER" }
        return method
    }

    private func safeRouteTemplate(_ value: String?) -> String {
        guard let value, value.hasPrefix("/"), value.utf8.count <= 512,
              !value.contains("?"), !value.contains("#"),
              value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            return "unmatched"
        }
        return value
    }

    private func safeTraceID(_ value: String?) -> String? {
        guard let value, value.utf8.count == 32,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }),
              value.contains(where: { $0 != "0" }) else { return nil }
        return value.lowercased()
    }
}

private func incremented(_ value: UInt64) -> UInt64 {
    value == .max ? .max : value + 1
}

private func saturatedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : value
}

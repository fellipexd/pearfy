import Foundation
import PearfyWeb

public struct MetricLabels: Hashable, Sendable, CustomStringConvertible {
    private struct Pair: Hashable, Sendable {
        let key: String
        let value: String
    }

    private let pairs: [Pair]

    public init() { pairs = [] }

    public init(_ values: [String: String]) throws {
        for key in values.keys where !Self.isValidIdentifier(key) {
            throw MetricsError.invalidLabelName(key)
        }
        if values.values.contains(where: { $0.utf8.count > 1_024 }) {
            throw MetricsError.labelValueTooLong(1_024)
        }
        pairs = values.sorted { $0.key < $1.key }.map { Pair(key: $0.key, value: $0.value) }
    }

    public var values: [String: String] {
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.key, $0.value) })
    }

    public var description: String {
        pairs.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    fileprivate var orderedPairs: [(String, String)] { pairs.map { ($0.key, $0.value) } }

    fileprivate static func isValidIdentifier(_ value: String) -> Bool {
        guard let first = value.utf8.first, first == 95 || (65...90).contains(first) || (97...122).contains(first) else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy {
            $0 == 95 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }
}

public enum MetricsError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidMetricName(String)
    case invalidLabelName(String)
    case labelValueTooLong(Int)
    case tooManyLabels(Int)
    case reservedLabelName(String)
    case cardinalityLimit(Int)
    case metricTypeConflict(String)
    case invalidValue
    case counterOverflow

    public var description: String {
        switch self {
        case .invalidMetricName(let name): "PEARFY_METRICS_001: invalid metric name '\(name)'"
        case .invalidLabelName(let name): "PEARFY_METRICS_002: invalid label name '\(name)'"
        case .labelValueTooLong(let maximum): "PEARFY_METRICS_003: maximum label value length is \(maximum) bytes"
        case .tooManyLabels(let maximum): "PEARFY_METRICS_004: maximum labels per series is \(maximum)"
        case .cardinalityLimit(let maximum): "PEARFY_METRICS_005: maximum metric series is \(maximum)"
        case .reservedLabelName(let name): "PEARFY_METRICS_006: label name '\(name)' is reserved for histogram output"
        case .metricTypeConflict(let name): "PEARFY_METRICS_007: metric '\(name)' is already registered with another type"
        case .invalidValue: "PEARFY_METRICS_008: metric values must be finite and non-negative"
        case .counterOverflow: "PEARFY_METRICS_009: metric counter overflow"
        }
    }
}

private struct MetricSeries: Hashable, Sendable {
    let name: String
    let labels: MetricLabels
}

private enum MetricKind: Sendable, Equatable { case counter, gauge, histogram }

private struct HistogramValue: Sendable {
    var count: UInt64 = 0
    var sum = 0.0
    var buckets: [UInt64]
}

/// In-memory Prometheus text registry with bounded series and label cardinality.
public actor MetricsRegistry {
    private static let defaultBuckets = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]

    private let maximumSeries: Int
    private let maximumLabelsPerSeries: Int
    private var kinds: [MetricSeries: MetricKind] = [:]
    private var counters: [MetricSeries: UInt64] = [:]
    private var gauges: [MetricSeries: Double] = [:]
    private var histograms: [MetricSeries: HistogramValue] = [:]

    public init(maximumSeries: Int = 1_000, maximumLabelsPerSeries: Int = 8) {
        self.maximumSeries = max(1, maximumSeries)
        self.maximumLabelsPerSeries = max(0, maximumLabelsPerSeries)
    }

    public func increment(_ name: String, by amount: UInt64 = 1, labels: MetricLabels = MetricLabels()) throws {
        let series = try register(name, labels: labels, kind: .counter)
        let (updated, overflow) = counters[series, default: 0].addingReportingOverflow(amount)
        guard !overflow else { throw MetricsError.counterOverflow }
        counters[series] = updated
    }

    public func setGauge(_ name: String, value: Double, labels: MetricLabels = MetricLabels()) throws {
        try setGauges([name: value], labels: labels)
    }

    public func setGauges(_ values: [String: Double], labels: MetricLabels = MetricLabels()) throws {
        guard values.values.allSatisfy(\.isFinite) else { throw MetricsError.invalidValue }
        for name in values.keys.sorted() {
            let series = try register(name, labels: labels, kind: .gauge)
            if let value = values[name] { gauges[series] = value }
        }
    }

    public func adjustGauge(_ name: String, by amount: Double, labels: MetricLabels = MetricLabels()) throws {
        guard amount.isFinite else { throw MetricsError.invalidValue }
        let series = try register(name, labels: labels, kind: .gauge)
        let updated = gauges[series, default: 0] + amount
        guard updated.isFinite else { throw MetricsError.invalidValue }
        gauges[series] = updated
    }

    public func observe(_ name: String, value: Double, labels: MetricLabels = MetricLabels()) throws {
        guard value.isFinite, value >= 0 else { throw MetricsError.invalidValue }
        guard labels.values["le"] == nil else { throw MetricsError.reservedLabelName("le") }
        let series = try register(name, labels: labels, kind: .histogram)
        var histogram = histograms[series] ?? HistogramValue(buckets: Array(repeating: 0, count: Self.defaultBuckets.count))
        let (count, overflow) = histogram.count.addingReportingOverflow(1)
        guard !overflow else { throw MetricsError.counterOverflow }
        let updatedSum = histogram.sum + value
        guard updatedSum.isFinite else { throw MetricsError.invalidValue }
        histogram.count = count
        histogram.sum = updatedSum
        for index in Self.defaultBuckets.indices where value <= Self.defaultBuckets[index] {
            histogram.buckets[index] += 1
        }
        histograms[series] = histogram
    }

    public func prometheusText() -> String {
        let series = kinds.keys.sorted {
            let left = "\($0.name)|\($0.labels.description)"
            let right = "\($1.name)|\($1.labels.description)"
            return left < right
        }
        var lines: [String] = []
        for item in series {
            switch kinds[item] {
            case .counter:
                lines.append("\(item.name)\(formattedLabels(item.labels)) \(counters[item, default: 0])")
            case .gauge:
                lines.append("\(item.name)\(formattedLabels(item.labels)) \(gauges[item, default: 0])")
            case .histogram:
                guard let histogram = histograms[item] else { continue }
                for index in Self.defaultBuckets.indices {
                    lines.append("\(item.name)_bucket\(formattedLabels(item.labels, extra: ("le", String(Self.defaultBuckets[index])))) \(histogram.buckets[index])")
                }
                lines.append("\(item.name)_bucket\(formattedLabels(item.labels, extra: ("le", "+Inf"))) \(histogram.count)")
                lines.append("\(item.name)_sum\(formattedLabels(item.labels)) \(histogram.sum)")
                lines.append("\(item.name)_count\(formattedLabels(item.labels)) \(histogram.count)")
            case nil:
                continue
            }
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    private func register(_ name: String, labels: MetricLabels, kind: MetricKind) throws -> MetricSeries {
        guard MetricLabels.isValidIdentifier(name), name.utf8.count <= 128 else {
            throw MetricsError.invalidMetricName(name)
        }
        guard labels.orderedPairs.count <= maximumLabelsPerSeries else {
            throw MetricsError.tooManyLabels(maximumLabelsPerSeries)
        }
        let series = MetricSeries(name: name, labels: labels)
        if let existingKind = kinds[series] {
            guard existingKind == kind else { throw MetricsError.metricTypeConflict(name) }
        } else {
            guard kinds.count < maximumSeries else { throw MetricsError.cardinalityLimit(maximumSeries) }
            kinds[series] = kind
        }
        return series
    }

    private func formattedLabels(_ labels: MetricLabels, extra: (String, String)? = nil) -> String {
        var pairs = labels.orderedPairs
        if let extra { pairs.append(extra) }
        guard !pairs.isEmpty else { return "" }
        let values = pairs.map { key, value in
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\(key)=\"\(escaped)\""
        }
        return "{\(values.joined(separator: ","))}"
    }
}

public enum HTTPMetricsMiddleware {
    public static func make(registry: MetricsRegistry) -> HTTPMiddleware {
        { request, next in
            let clock = ContinuousClock()
            let start = clock.now
            let routeLabels = try? MetricLabels([
                "method": request.method.description.lowercased(),
                "route": request.contextValue(HTTPRequest.routeTemplateContextKey) ?? "unmatched"
            ])
            var gaugeRecorded = false
            if let routeLabels {
                do {
                    try await registry.adjustGauge("pearfy_http_requests_in_flight", by: 1, labels: routeLabels)
                    gaugeRecorded = true
                } catch {}
            }
            let response = await next(request)
            if gaugeRecorded, let routeLabels {
                try? await registry.adjustGauge("pearfy_http_requests_in_flight", by: -1, labels: routeLabels)
            }
            let elapsed = start.duration(to: clock.now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
            let labels = try? MetricLabels([
                "method": request.method.description.lowercased(),
                "route": request.contextValue(HTTPRequest.routeTemplateContextKey) ?? "unmatched",
                "status_class": "\(response.status / 100)xx"
            ])
            if let labels {
                try? await registry.increment("pearfy_http_requests_total", labels: labels)
                try? await registry.observe("pearfy_http_request_duration_seconds", value: seconds, labels: labels)
            }
            return response
        }
    }
}

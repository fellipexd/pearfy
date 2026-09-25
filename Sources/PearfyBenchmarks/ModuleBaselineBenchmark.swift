import Foundation
import PearfyCache
import PearfyCloud
import PearfyJobs
import PearfyMessaging
import PearfyObservability

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

enum ModuleBaselineBenchmark {
    private struct Sample {
        let module: String
        let scenario: String
        let operations: Int
        let run: Int
        let elapsedMilliseconds: Double
        let peakRSSBytes: Int64
    }

    private struct CacheValue: Codable, Sendable {
        let number: Int
    }

    static func run(runs: Int, operations: Int, concurrency: Int) async throws {
        var samples: [Sample] = []

        for run in 1...runs {
            let cache = InMemoryCache(capacity: max(operations, 1))
            let cacheKey = try CacheKey(namespace: "benchmark", value: "hot")
            try await cache.set(CacheValue(number: 0), for: cacheKey)
            samples.append(Sample(
                module: "PearfyCache",
                scenario: "cache_hit",
                operations: operations,
                run: run,
                elapsedMilliseconds: try await measure {
                    for _ in 0..<operations {
                        _ = try await cache.value(for: cacheKey, as: CacheValue.self)
                    }
                },
                peakRSSBytes: peakResidentMemoryBytes()
            ))
            samples.append(Sample(
                module: "PearfyCache",
                scenario: "cache_write_read",
                operations: operations,
                run: run,
                elapsedMilliseconds: try await measure {
                    for index in 0..<operations {
                        try await cache.set(CacheValue(number: index), for: cacheKey)
                        _ = try await cache.value(for: cacheKey, as: CacheValue.self)
                    }
                },
                peakRSSBytes: peakResidentMemoryBytes()
            ))

            let broker = InMemoryMessageBroker(
                capacity: 1,
                maximumPayloadBytes: 64,
                maximumQueuedBytes: 64,
                maximumIdempotencyKeys: operations
            )
            let payload = Data([0x50])
            samples.append(Sample(
                module: "PearfyMessaging",
                scenario: "message_publish_receive_ack",
                operations: operations,
                run: run,
                elapsedMilliseconds: try await measure {
                    for index in 0..<operations {
                        try await broker.publish(
                            topic: "benchmark",
                            payload: payload,
                            idempotencyKey: "event-\(index)"
                        )
                        guard let message = try await broker.receive(topic: "benchmark") else {
                            throw ModuleBenchmarkError.messageUnavailable
                        }
                        try await broker.acknowledge(message.id)
                    }
                },
                peakRSSBytes: peakResidentMemoryBytes()
            ))

            let httpClient = CloudHTTPClient(
                transport: ImmediateHTTPTransport(),
                retryPolicy: HTTPRetryPolicy(maximumAttempts: 1),
                maximumConcurrentRequests: concurrency,
                maximumQueuedRequests: operations
            )
            let request = URLRequest(url: URL(string: "https://benchmark.invalid/health")!)
            let workerCount = min(operations, concurrency)
            samples.append(Sample(
                module: "PearfyCloud",
                scenario: "outbound_http_stub",
                operations: operations,
                run: run,
                elapsedMilliseconds: try await measure {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for worker in 0..<workerCount {
                            let workerOperations = operations / workerCount + (worker < operations % workerCount ? 1 : 0)
                            group.addTask {
                                for _ in 0..<workerOperations {
                                    _ = try await httpClient.send(request)
                                }
                            }
                        }
                        try await group.waitForAll()
                    }
                },
                peakRSSBytes: peakResidentMemoryBytes()
            ))

            let metrics = MetricsRegistry()
            samples.append(Sample(
                module: "PearfyObservability",
                scenario: "counter_increment",
                operations: operations,
                run: run,
                elapsedMilliseconds: try await measure {
                    for _ in 0..<operations { try await metrics.increment("pearfy_benchmark_operations_total") }
                },
                peakRSSBytes: peakResidentMemoryBytes()
            ))

            let scheduler = JobScheduler()
            try await scheduler.schedule("benchmark", every: .seconds(60)) {}
            samples.append(Sample(
                module: "PearfyJobs",
                scenario: "empty_scheduler_start_stop",
                operations: 1,
                run: run,
                elapsedMilliseconds: try await measure {
                    try await scheduler.start()
                    try await scheduler.stop()
                },
                peakRSSBytes: peakResidentMemoryBytes()
            ))
        }

        print("module_kind,module,scenario,operations,run,elapsed_ms,peak_rss_bytes")
        for sample in samples {
            print("sample,\(sample.module),\(sample.scenario),\(sample.operations),\(sample.run),\(format(sample.elapsedMilliseconds)),\(sample.peakRSSBytes)")
        }
        let grouped = Dictionary(grouping: samples) { "\($0.module)|\($0.scenario)|\($0.operations)" }
        for key in grouped.keys.sorted() {
            guard let values = grouped[key], let first = values.first else { continue }
            let median = medianValue(values.map(\.elapsedMilliseconds))
            let peakRSS = values.map(\.peakRSSBytes).max() ?? 0
            print("median,\(first.module),\(first.scenario),\(first.operations),0,\(format(median)),\(peakRSS)")
        }
    }

    private static func measure(_ operation: @Sendable () async throws -> Void) async rethrows -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        try await operation()
        let duration = start.duration(to: clock.now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1_000_000_000_000_000
    }

    private static func medianValue(_ values: [Double]) -> Double {
        let ordered = values.sorted()
        let middle = ordered.count / 2
        if ordered.count.isMultiple(of: 2) {
            return (ordered[middle - 1] + ordered[middle]) / 2
        }
        return ordered[middle]
    }

    private static func format(_ value: Double) -> String { String(format: "%.3f", value) }

    private static func peakResidentMemoryBytes() -> Int64 {
        #if os(macOS) || os(Linux)
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
        #if os(macOS)
        return Int64(usage.ru_maxrss)
        #else
        return Int64(usage.ru_maxrss) * 1_024
        #endif
        #else
        return -1
        #endif
    }
}

private struct ImmediateHTTPTransport: CloudHTTPTransport {
    func send(_ request: URLRequest) async throws -> CloudHTTPResponse {
        CloudHTTPResponse(statusCode: 200)
    }
}

private enum ModuleBenchmarkError: Error {
    case messageUnavailable
}

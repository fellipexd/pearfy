import Foundation
import PearfyConfiguration
import PearfyContext
import PearfyDI

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

@main
struct PearfyBenchmarks {
    private struct Options: Sendable {
        var runs = 5
        var registrationCounts = [10, 100, 1_000]
        var resolves = 10_000
        var concurrentResolves = 100
        var includeHTTP = false
        var includeHTTPObservability = false
        var includeModuleBaselines = false
        var runDI = true
        var httpRequests = 500
    }

    private struct Sample {
        let scenario: String
        let registrations: Int
        let operations: Int
        let run: Int
        let elapsedMilliseconds: Double
        let peakRSSBytes: Int64
        let factoryCalls: Int
    }

    static func main() async throws {
        let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
        var samples: [Sample] = []

        if options.runDI {
        print("kind,scenario,registrations,operations,run,elapsed_ms,peak_rss_bytes,factory_calls")

        for registrationCount in options.registrationCounts {
            for run in 1...options.runs {
                if run == 1 {
                    _ = try await registryBuild(registrationCount)
                }
                let elapsed = try await measure {
                    _ = try await registryBuild(registrationCount)
                }
                samples.append(Sample(
                    scenario: "registry_build",
                    registrations: registrationCount,
                    operations: registrationCount,
                    run: run,
                    elapsedMilliseconds: elapsed,
                    peakRSSBytes: peakResidentMemoryBytes(),
                    factoryCalls: 0
                ))
            }
        }

        for registrationCount in options.registrationCounts {
            let scaledResolveCount = min(options.resolves, max(100, 100_000 / registrationCount))
            for run in 1...options.runs {
                let qualifier = "provider-\(registrationCount - 1)"
                let qualifiedContainer = ServiceContainer()
                for index in 0..<registrationCount {
                    try await qualifiedContainer.register(
                        BenchmarkValue.self,
                        qualifier: "provider-\(index)"
                    ) { _ in BenchmarkValue(value: index) }
                }
                for _ in 0..<min(100, scaledResolveCount) {
                    _ = try await qualifiedContainer.resolve(BenchmarkValue.self, qualifier: qualifier)
                }
                let qualifiedElapsed = try await measure {
                    for _ in 0..<scaledResolveCount {
                        _ = try await qualifiedContainer.resolve(BenchmarkValue.self, qualifier: qualifier)
                    }
                }
                samples.append(Sample(
                    scenario: "qualified_lookup_scaled",
                    registrations: registrationCount,
                    operations: scaledResolveCount,
                    run: run,
                    elapsedMilliseconds: qualifiedElapsed,
                    peakRSSBytes: peakResidentMemoryBytes(),
                    factoryCalls: 1
                ))

                let primaryContainer = ServiceContainer()
                for index in 0..<registrationCount {
                    try await primaryContainer.register(
                        BenchmarkValue.self,
                        qualifier: "provider-\(index)",
                        primary: index == registrationCount - 1
                    ) { _ in BenchmarkValue(value: index) }
                }
                for _ in 0..<min(100, scaledResolveCount) { _ = try await primaryContainer.resolve(BenchmarkValue.self) }
                let primaryElapsed = try await measure {
                    for _ in 0..<scaledResolveCount {
                        _ = try await primaryContainer.resolve(BenchmarkValue.self)
                    }
                }
                samples.append(Sample(
                    scenario: "primary_lookup_scaled",
                    registrations: registrationCount,
                    operations: scaledResolveCount,
                    run: run,
                    elapsedMilliseconds: primaryElapsed,
                    peakRSSBytes: peakResidentMemoryBytes(),
                    factoryCalls: 1
                ))
            }
        }

        for run in 1...options.runs {
            let singletonContainer = ServiceContainer()
            try await singletonContainer.register(BenchmarkValue.self, qualifier: "hot") { _ in
                BenchmarkValue(value: 1)
            }
            for _ in 0..<100 { _ = try await singletonContainer.resolve(BenchmarkValue.self, qualifier: "hot") }
            let singletonElapsed = try await measure {
                for _ in 0..<options.resolves {
                    _ = try await singletonContainer.resolve(BenchmarkValue.self, qualifier: "hot")
                }
            }
            samples.append(Sample(
                scenario: "singleton_resolve",
                registrations: 1,
                operations: options.resolves,
                run: run,
                elapsedMilliseconds: singletonElapsed,
                peakRSSBytes: peakResidentMemoryBytes(),
                factoryCalls: 1
            ))

            let transientContainer = ServiceContainer()
            try await transientContainer.register(BenchmarkValue.self, scope: .transient) { _ in
                BenchmarkValue(value: 2)
            }
            for _ in 0..<100 { _ = try await transientContainer.resolve(BenchmarkValue.self) }
            let transientElapsed = try await measure {
                for _ in 0..<options.resolves {
                    _ = try await transientContainer.resolve(BenchmarkValue.self)
                }
            }
            samples.append(Sample(
                scenario: "transient_resolve",
                registrations: 1,
                operations: options.resolves,
                run: run,
                elapsedMilliseconds: transientElapsed,
                peakRSSBytes: peakResidentMemoryBytes(),
                factoryCalls: options.resolves + 100
            ))

            let contentionCounter = FactoryCallCounter()
            let contentionContainer = ServiceContainer()
            try await contentionContainer.register(BenchmarkValue.self, qualifier: "contended") { _ in
                await contentionCounter.increment()
                try await Task.sleep(for: .milliseconds(2))
                return BenchmarkValue(value: 3)
            }
            let contentionElapsed = try await measure {
                try await withThrowingTaskGroup(of: BenchmarkValue.self) { group in
                    for _ in 0..<options.concurrentResolves {
                        group.addTask {
                            try await contentionContainer.resolve(BenchmarkValue.self, qualifier: "contended")
                        }
                    }
                    for try await _ in group {}
                }
            }
            samples.append(Sample(
                scenario: "singleton_contention",
                registrations: 1,
                operations: options.concurrentResolves,
                run: run,
                elapsedMilliseconds: contentionElapsed,
                peakRSSBytes: peakResidentMemoryBytes(),
                factoryCalls: await contentionCounter.value
            ))

            let requestCounter = FactoryCallCounter()
            let requestContainer = ServiceContainer()
            try await requestContainer.register(BenchmarkValue.self, scope: .request) { _ in
                await requestCounter.increment()
                return BenchmarkValue(value: 4)
            }
            let requestScope = await requestContainer.makeRequestScope()
            for _ in 0..<100 { _ = try await requestScope.resolve(BenchmarkValue.self) }
            let scopedElapsed = try await measure {
                for _ in 0..<options.resolves {
                    _ = try await requestScope.resolve(BenchmarkValue.self)
                }
            }
            samples.append(Sample(
                scenario: "request_scope_cached_resolve",
                registrations: 1,
                operations: options.resolves,
                run: run,
                elapsedMilliseconds: scopedElapsed,
                peakRSSBytes: peakResidentMemoryBytes(),
                factoryCalls: await requestCounter.value
            ))
            await requestScope.close()

            let perRequestCount = min(options.resolves, 1_000)
            let perRequestCounter = FactoryCallCounter()
            let perRequestContainer = ServiceContainer()
            try await perRequestContainer.register(BenchmarkValue.self, scope: .request) { _ in
                await perRequestCounter.increment()
                return BenchmarkValue(value: 5)
            }
            let perRequestElapsed = try await measure {
                for _ in 0..<perRequestCount {
                    let scope = await perRequestContainer.makeRequestScope()
                    _ = try await scope.resolve(BenchmarkValue.self)
                    await scope.close()
                }
            }
            samples.append(Sample(
                scenario: "request_scope_create_resolve_close",
                registrations: 1,
                operations: perRequestCount,
                run: run,
                elapsedMilliseconds: perRequestElapsed,
                peakRSSBytes: peakResidentMemoryBytes(),
                factoryCalls: await perRequestCounter.value
            ))

            let context = ApplicationContext(
                container: ServiceContainer(),
                configuration: try ConfigurationLoader.load()
            )
            let lifecycleElapsed = try await measure {
                try await context.start()
                try await context.stop()
            }
            samples.append(Sample(
                scenario: "empty_context_start_stop",
                registrations: 0,
                operations: 1,
                run: run,
                elapsedMilliseconds: lifecycleElapsed,
                peakRSSBytes: peakResidentMemoryBytes(),
                factoryCalls: 0
            ))
        }

        for sample in samples {
            print("sample,\(sample.scenario),\(sample.registrations),\(sample.operations),\(sample.run),\(format(sample.elapsedMilliseconds)),\(sample.peakRSSBytes),\(sample.factoryCalls)")
        }

        let grouped = Dictionary(grouping: samples) { sample in
            "\(sample.scenario)|\(sample.registrations)|\(sample.operations)"
        }
        for key in grouped.keys.sorted() {
            guard let values = grouped[key], let first = values.first else { continue }
            let median = medianValue(values.map(\.elapsedMilliseconds))
            let peakRSS = values.map(\.peakRSSBytes).max() ?? 0
            print("median,\(first.scenario),\(first.registrations),\(first.operations),0,\(format(median)),\(peakRSS),\(first.factoryCalls)")
        }
        }

        if options.includeHTTP {
            try await HTTPBenchmark.run(runs: options.runs, requests: options.httpRequests)
        }
        if options.includeHTTPObservability {
            try await HTTPBenchmark.runObservability(runs: options.runs, requests: options.httpRequests)
        }
        if options.includeModuleBaselines {
            try await ModuleBaselineBenchmark.run(
                runs: options.runs,
                operations: options.resolves,
                concurrency: options.concurrentResolves
            )
        }
    }

    private static func registryBuild(_ count: Int) async throws -> ServiceContainer {
        let container = ServiceContainer()
        for index in 0..<count {
            try await container.register(BenchmarkValue.self, qualifier: "component-\(index)") { _ in
                BenchmarkValue(value: index)
            }
        }
        _ = try await container.validateGraph()
        return container
    }

    private static func measure(_ operation: @Sendable () async throws -> Void) async rethrows -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        try await operation()
        let duration = start.duration(to: clock.now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1_000_000_000_000_000
    }

    private static func parseOptions(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--http" {
                options.includeHTTP = true
                index += 1
                continue
            }
            if flag == "--http-only" {
                options.includeHTTP = true
                options.runDI = false
                index += 1
                continue
            }
            if flag == "--http-observability-only" {
                options.includeHTTPObservability = true
                options.runDI = false
                index += 1
                continue
            }
            if flag == "--module-baselines-only" {
                options.includeModuleBaselines = true
                options.runDI = false
                index += 1
                continue
            }
            guard index + 1 < arguments.count else {
                throw BenchmarkError.invalidArguments("expected a value after \(flag)")
            }
            let rawValue = arguments[index + 1]
            switch flag {
            case "--runs":
                guard let value = Int(rawValue) else { throw BenchmarkError.invalidArguments("--runs expects an integer") }
                options.runs = value
            case "--resolves":
                guard let value = Int(rawValue) else { throw BenchmarkError.invalidArguments("--resolves expects an integer") }
                options.resolves = value
            case "--concurrency":
                guard let value = Int(rawValue) else { throw BenchmarkError.invalidArguments("--concurrency expects an integer") }
                options.concurrentResolves = value
            case "--http-requests":
                guard let value = Int(rawValue) else { throw BenchmarkError.invalidArguments("--http-requests expects an integer") }
                options.httpRequests = value
            case "--registrations":
                let parts = rawValue.split(separator: ",")
                options.registrationCounts = parts.compactMap { Int($0) }
                guard options.registrationCounts.count == parts.count else {
                    throw BenchmarkError.invalidArguments("--registrations expects comma-separated integers")
                }
                guard !options.registrationCounts.isEmpty else {
                    throw BenchmarkError.invalidArguments("--registrations expects comma-separated positive integers")
                }
            default:
                throw BenchmarkError.invalidArguments("unknown option \(flag)")
            }
            index += 2
        }

        guard options.runs > 0,
              options.resolves > 0,
              options.concurrentResolves > 0,
              options.httpRequests > 0,
              options.registrationCounts.allSatisfy({ $0 > 0 }) else {
            throw BenchmarkError.invalidArguments("all counts must be positive")
        }
        return options
    }

    private static func medianValue(_ values: [Double]) -> Double {
        let ordered = values.sorted()
        let middle = ordered.count / 2
        if ordered.count.isMultiple(of: 2) {
            return (ordered[middle - 1] + ordered[middle]) / 2
        }
        return ordered[middle]
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

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

private struct BenchmarkValue: Sendable {
    let value: Int
}

private actor FactoryCallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case invalidArguments(String)

    var description: String {
        switch self {
        case .invalidArguments(let message): "\(message)\nUsage: pearfy-bench [--runs N] [--registrations 10,100,1000] [--resolves N] [--concurrency N] [--http|--http-only|--http-observability-only|--module-baselines-only] [--http-requests N]"
        }
    }
}

import Foundation
import NIOCore
@preconcurrency import NIOHTTP1
import NIOPosix
import PearfyNIO
import PearfyObservability
import PearfyWeb

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

enum HTTPBenchmark {
    private struct JSONPayload: Codable, Sendable, Equatable {
        let message: String
    }

    private struct LoadResult: Sendable {
        var latencies: [Double] = []
        var errors = 0
    }

    private struct Sample: Sendable {
        let server: String
        let scenario: String
        let concurrency: Int
        let requests: Int
        let run: Int
        let elapsedMilliseconds: Double
        let requestsPerSecond: Double
        let p50: Double
        let p95: Double
        let p99: Double
        let errors: Int
        let peakRSSBytes: Int64
    }

    static func run(runs: Int, requests: Int) async throws {
        let jsonPayload = JSONPayload(message: "pear")
        let jsonBody = try JSONEncoder().encode(jsonPayload)
        let scenarios: [(String, Data)] = [
            ("plaintext", Data("pear".utf8)),
            ("json", jsonBody)
        ]
        var samples: [Sample] = []

        let bareServer = BareHTTPBenchmarkServer()
        try await bareServer.start()
        FileHandle.standardError.write(Data("http-benchmark: bare NIO listener ready\n".utf8))
        guard let barePort = await bareServer.port else {
            try await bareServer.stop()
            throw HTTPBenchmarkError.listenerDidNotBind
        }
        do {
            samples += try await benchmarkServer(
                name: "nio_bare",
                port: barePort,
                scenarios: scenarios,
                runs: runs,
                requests: requests
            )
            FileHandle.standardError.write(Data("http-benchmark: bare NIO measurements complete\n".utf8))
            try await bareServer.stop()
        } catch {
            try? await bareServer.stop()
            throw error
        }

        let router = HTTPRouter()
        try await router.get("/plaintext") { _ in .text("pear") }
        try await router.get("/json") { _ in try .json(jsonPayload) }
        let pearfyServer = PearfyHTTPServer(router: router, host: "127.0.0.1", port: 0)
        try await pearfyServer.start()
        FileHandle.standardError.write(Data("http-benchmark: Pearfy listener ready\n".utf8))
        guard let pearfyPort = await pearfyServer.boundPort() else {
            try await pearfyServer.stop()
            throw HTTPBenchmarkError.listenerDidNotBind
        }
        do {
            samples += try await benchmarkServer(
                name: "pearfy_nio",
                port: pearfyPort,
                scenarios: scenarios,
                runs: runs,
                requests: requests
            )
            FileHandle.standardError.write(Data("http-benchmark: Pearfy measurements complete\n".utf8))
            try await pearfyServer.stop()
        } catch {
            try? await pearfyServer.stop()
            throw error
        }

        print("http_kind,server,scenario,concurrency,requests,run,elapsed_ms,rps,p50_ms,p95_ms,p99_ms,errors,peak_rss_bytes")
        for sample in samples {
            print("sample,\(sample.server),\(sample.scenario),\(sample.concurrency),\(sample.requests),\(sample.run),\(format(sample.elapsedMilliseconds)),\(format(sample.requestsPerSecond)),\(format(sample.p50)),\(format(sample.p95)),\(format(sample.p99)),\(sample.errors),\(sample.peakRSSBytes)")
        }

        let grouped = Dictionary(grouping: samples) {
            "\($0.server)|\($0.scenario)|\($0.concurrency)|\($0.requests)"
        }
        for key in grouped.keys.sorted() {
            guard let values = grouped[key], let first = values.first else { continue }
            let elapsed = format(median(values.map(\.elapsedMilliseconds)))
            let rps = format(median(values.map(\.requestsPerSecond)))
            let p50 = format(median(values.map(\.p50)))
            let p95 = format(median(values.map(\.p95)))
            let p99 = format(median(values.map(\.p99)))
            let errors = values.map(\.errors).max() ?? 0
            let peakRSS = values.map(\.peakRSSBytes).max() ?? 0
            print("median,\(first.server),\(first.scenario),\(first.concurrency),\(first.requests),0,\(elapsed),\(rps),\(p50),\(p95),\(p99),\(errors),\(peakRSS)")
        }
    }

    static func runObservability(runs: Int, requests: Int) async throws {
        let jsonPayload = JSONPayload(message: "pear")
        let jsonBody = try JSONEncoder().encode(jsonPayload)
        let scenarios: [(String, Data)] = [
            ("plaintext", Data("pear".utf8)),
            ("json", jsonBody)
        ]
        var samples: [Sample] = []

        let uninstrumentedRouter = HTTPRouter()
        try await uninstrumentedRouter.get("/plaintext") { _ in .text("pear") }
        try await uninstrumentedRouter.get("/json") { _ in try .json(jsonPayload) }
        let uninstrumentedServer = PearfyHTTPServer(router: uninstrumentedRouter, host: "127.0.0.1", port: 0)
        try await uninstrumentedServer.start()
        guard let uninstrumentedPort = await uninstrumentedServer.boundPort() else {
            try await uninstrumentedServer.stop()
            throw HTTPBenchmarkError.listenerDidNotBind
        }
        do {
            samples += try await benchmarkServer(
                name: "pearfy_metrics_off",
                port: uninstrumentedPort,
                scenarios: scenarios,
                runs: runs,
                requests: requests
            )
            try await uninstrumentedServer.stop()
        } catch {
            try? await uninstrumentedServer.stop()
            throw error
        }

        let instrumentedRouter = HTTPRouter()
        try await instrumentedRouter.use(HTTPMetricsMiddleware.make(registry: MetricsRegistry()))
        try await instrumentedRouter.get("/plaintext") { _ in .text("pear") }
        try await instrumentedRouter.get("/json") { _ in try .json(jsonPayload) }
        let instrumentedServer = PearfyHTTPServer(router: instrumentedRouter, host: "127.0.0.1", port: 0)
        try await instrumentedServer.start()
        guard let instrumentedPort = await instrumentedServer.boundPort() else {
            try await instrumentedServer.stop()
            throw HTTPBenchmarkError.listenerDidNotBind
        }
        do {
            samples += try await benchmarkServer(
                name: "pearfy_metrics_on",
                port: instrumentedPort,
                scenarios: scenarios,
                runs: runs,
                requests: requests
            )
            try await instrumentedServer.stop()
        } catch {
            try? await instrumentedServer.stop()
            throw error
        }

        print("http_kind,server,scenario,concurrency,requests,run,elapsed_ms,rps,p50_ms,p95_ms,p99_ms,errors,peak_rss_bytes")
        for sample in samples {
            print("sample,\(sample.server),\(sample.scenario),\(sample.concurrency),\(sample.requests),\(sample.run),\(format(sample.elapsedMilliseconds)),\(format(sample.requestsPerSecond)),\(format(sample.p50)),\(format(sample.p95)),\(format(sample.p99)),\(sample.errors),\(sample.peakRSSBytes)")
        }
        let grouped = Dictionary(grouping: samples) {
            "\($0.server)|\($0.scenario)|\($0.concurrency)|\($0.requests)"
        }
        for key in grouped.keys.sorted() {
            guard let values = grouped[key], let first = values.first else { continue }
            let elapsed = format(median(values.map(\.elapsedMilliseconds)))
            let rps = format(median(values.map(\.requestsPerSecond)))
            let p50 = format(median(values.map(\.p50)))
            let p95 = format(median(values.map(\.p95)))
            let p99 = format(median(values.map(\.p99)))
            let errors = values.map(\.errors).max() ?? 0
            let peakRSS = values.map(\.peakRSSBytes).max() ?? 0
            print("median,\(first.server),\(first.scenario),\(first.concurrency),\(first.requests),0,\(elapsed),\(rps),\(p50),\(p95),\(p99),\(errors),\(peakRSS)")
        }
    }

    private static func benchmarkServer(
        name: String,
        port: Int,
        scenarios: [(String, Data)],
        runs: Int,
        requests: Int
    ) async throws -> [Sample] {
        var samples: [Sample] = []
        for (scenario, expectedBody) in scenarios {
            let url = URL(string: "http://127.0.0.1:\(port)/\(scenario)")!
            for _ in 0..<min(10, requests) {
                _ = try await send(url: url, expectedBody: expectedBody)
            }
            for concurrency in [1, 10, 100] {
                for run in 1...runs {
                    let start = ContinuousClock.now
                    let result = try await load(url: url, expectedBody: expectedBody, requests: requests, concurrency: concurrency)
                    let duration = start.duration(to: ContinuousClock.now).components
                    let elapsedMilliseconds = Double(duration.seconds) * 1_000
                        + Double(duration.attoseconds) / 1_000_000_000_000_000
                    samples.append(Sample(
                        server: name,
                        scenario: scenario,
                        concurrency: min(concurrency, requests),
                        requests: requests,
                        run: run,
                        elapsedMilliseconds: elapsedMilliseconds,
                        requestsPerSecond: Double(requests) / max(elapsedMilliseconds / 1_000, 0.000_001),
                        p50: percentile(result.latencies, 0.50),
                        p95: percentile(result.latencies, 0.95),
                        p99: percentile(result.latencies, 0.99),
                        errors: result.errors,
                        peakRSSBytes: peakResidentMemoryBytes()
                    ))
                }
            }
        }
        return samples
    }

    private static func load(url: URL, expectedBody: Data, requests: Int, concurrency: Int) async throws -> LoadResult {
        let workerCount = min(requests, concurrency)
        let baseCount = requests / workerCount
        let extra = requests % workerCount
        return try await withThrowingTaskGroup(of: LoadResult.self) { group in
            for worker in 0..<workerCount {
                let count = baseCount + (worker < extra ? 1 : 0)
                group.addTask {
                    var result = LoadResult()
                    result.latencies.reserveCapacity(count)
                    for _ in 0..<count {
                        let start = ContinuousClock.now
                        let (data, response) = try await URLSession.shared.data(from: url)
                        let duration = start.duration(to: ContinuousClock.now).components
                        result.latencies.append(
                            Double(duration.seconds) * 1_000
                                + Double(duration.attoseconds) / 1_000_000_000_000_000
                        )
                        if (response as? HTTPURLResponse)?.statusCode != 200 || data != expectedBody {
                            result.errors += 1
                        }
                    }
                    return result
                }
            }
            var combined = LoadResult()
            combined.latencies.reserveCapacity(requests)
            for try await result in group {
                combined.latencies.append(contentsOf: result.latencies)
                combined.errors += result.errors
            }
            return combined
        }
    }

    private static func send(url: URL, expectedBody: Data) async throws -> Bool {
        let (body, response) = try await URLSession.shared.data(from: url)
        return (response as? HTTPURLResponse)?.statusCode == 200 && body == expectedBody
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let ordered = values.sorted()
        let index = min(ordered.count - 1, Int((Double(ordered.count) * percentile).rounded(.up)) - 1)
        return ordered[max(0, index)]
    }

    private static func median(_ values: [Double]) -> Double {
        let ordered = values.sorted()
        let midpoint = ordered.count / 2
        return ordered.count.isMultiple(of: 2)
            ? (ordered[midpoint - 1] + ordered[midpoint]) / 2
            : ordered[midpoint]
    }

    private static func format(_ value: Double) -> String { String(format: "%.3f", value) }

    private static func peakResidentMemoryBytes() -> Int64 {
        #if os(macOS) || os(Linux)
        var usage = rusage()
        let currentProcess: Int32 = 0 // RUSAGE_SELF on Darwin and Linux.
        guard getrusage(currentProcess, &usage) == 0 else { return -1 }
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

private actor BareHTTPBenchmarkServer {
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private let activeConnections = BareHTTPConnections()

    var port: Int? { channel?.localAddress?.port }

    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let activeConnections = self.activeConnections
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    activeConnections.insert(channel)
                    channel.closeFuture.whenComplete { _ in activeConnections.remove(channel) }
                    return channel.pipeline.configureHTTPServerPipeline()
                        .flatMap { channel.pipeline.addHandler(BareHTTPHandler()) }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            self.group = group
            self.channel = channel
        } catch {
            try await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async throws {
        guard let group else { return }
        channel?.close(promise: nil)
        activeConnections.closeAll()
        channel = nil
        self.group = nil
        try await group.shutdownGracefully()
    }
}

private final class BareHTTPConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]

    func insert(_ channel: Channel) {
        lock.lock()
        channels[ObjectIdentifier(channel)] = channel
        lock.unlock()
    }

    func remove(_ channel: Channel) {
        lock.lock()
        channels.removeValue(forKey: ObjectIdentifier(channel))
        lock.unlock()
    }

    func closeAll() {
        lock.lock()
        let current = Array(channels.values)
        lock.unlock()
        for channel in current { channel.close(promise: nil) }
    }
}

private final class BareHTTPHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .head(let request) = Self.unwrapInboundIn(data) else { return }
        let path = request.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let body: Data
        let contentType: String
        switch path {
        case "/plaintext":
            body = Data("pear".utf8)
            contentType = "text/plain; charset=utf-8"
        case "/json":
            body = Data(#"{"message":"pear"}"#.utf8)
            contentType = "application/json; charset=utf-8"
        default:
            body = Data("Not Found".utf8)
            contentType = "text/plain; charset=utf-8"
        }

        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: contentType)
        headers.add(name: "content-length", value: String(body.count))
        let head = HTTPResponseHead(version: request.version, status: path == "/plaintext" || path == "/json" ? .ok : .notFound, headers: headers)
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(Self.wrapOutboundOut(.head(head)), promise: nil)
        context.write(Self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
    }
}

private enum HTTPBenchmarkError: Error {
    case listenerDidNotBind
}

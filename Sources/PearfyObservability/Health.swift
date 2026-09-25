import Foundation
import PearfyWeb

public enum HealthStatus: String, Codable, Sendable, Equatable {
    case healthy
    case degraded
    case unhealthy
}

public struct HealthCheck: Codable, Sendable, Equatable {
    public let name: String
    public let status: HealthStatus
}

public struct HealthReport: Codable, Sendable, Equatable {
    public let status: HealthStatus
    public let checks: [HealthCheck]
}

public enum ReadinessState: String, Sendable, Equatable {
    case starting
    case ready
    case draining
    case stopped
}

public actor ReadinessGate {
    public private(set) var state: ReadinessState = .starting

    public init() {}

    public func markReady() { state = .ready }
    public func markDraining() { state = .draining }
    public func markStopped() { state = .stopped }
    public func isReady() -> Bool { state == .ready }
}

public enum HealthRegistryError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidName
    case duplicateCheck(String)
    case maximumChecks(Int)

    public var description: String {
        switch self {
        case .invalidName: "PEARFY_HEALTH_001: health check name must be a bounded identifier"
        case .duplicateCheck(let name): "PEARFY_HEALTH_002: duplicate health check '\(name)'"
        case .maximumChecks(let maximum): "PEARFY_HEALTH_003: maximum registered health checks is \(maximum)"
        }
    }
}

public actor HealthRegistry {
    private typealias Probe = @Sendable () async throws -> HealthStatus
    private let maximumChecks: Int
    private var probes: [String: Probe] = [:]

    public init(maximumChecks: Int = 64) {
        self.maximumChecks = max(1, maximumChecks)
    }

    public func register(
        _ name: String,
        probe: @escaping @Sendable () async throws -> HealthStatus
    ) throws {
        guard !name.isEmpty,
              name.utf8.count <= 128,
              name.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
              }) else {
            throw HealthRegistryError.invalidName
        }
        guard probes[name] == nil else { throw HealthRegistryError.duplicateCheck(name) }
        guard probes.count < maximumChecks else { throw HealthRegistryError.maximumChecks(maximumChecks) }
        probes[name] = probe
    }

    public func evaluate(timeoutPerCheck: Duration = .seconds(2)) async -> HealthReport {
        let snapshot = probes.sorted { $0.key < $1.key }
        let checks = await withTaskGroup(of: HealthCheck.self, returning: [HealthCheck].self) { group in
            for (name, probe) in snapshot {
                group.addTask {
                    await Self.run(name: name, probe: probe, timeout: max(.zero, timeoutPerCheck))
                }
            }
            var results: [HealthCheck] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.name < $1.name }
        }
        let status: HealthStatus
        if checks.contains(where: { $0.status == .unhealthy }) {
            status = .unhealthy
        } else if checks.contains(where: { $0.status == .degraded }) {
            status = .degraded
        } else {
            status = .healthy
        }
        return HealthReport(status: status, checks: checks)
    }

    private static func run(name: String, probe: @escaping Probe, timeout: Duration) async -> HealthCheck {
        let race = HealthCheckRace()
        let probeTask = Task {
            do { race.resolve(try await probe()) }
            catch { race.resolve(.unhealthy) }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                race.resolve(.unhealthy)
            } catch {}
        }
        let status = await race.wait()
        probeTask.cancel()
        timeoutTask.cancel()
        return HealthCheck(name: name, status: status)
    }
}

private final class HealthCheckRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HealthStatus, Never>?
    private var result: HealthStatus?

    func wait() async -> HealthStatus {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ status: HealthStatus) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = status
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: status)
    }
}

public enum HealthRoutes {
    public static func install(
        on router: HTTPRouter,
        registry: HealthRegistry,
        readiness: ReadinessGate,
        metrics: MetricsRegistry? = nil
    ) async throws {
        try await router.get("/health/live") { _ in
            .text("ok")
        }
        try await router.get("/health/ready") { _ in
            let report = await registry.evaluate()
            let isReady = await readiness.isReady()
            let status = isReady && report.status != .unhealthy ? HTTPStatus.ok.rawValue : HTTPStatus.serviceUnavailable.rawValue
            return (try? HTTPResponse.json(report, status: status)) ?? HTTPError.internalServerError.response
        }
        if let metrics {
            try await router.get("/metrics", access: .authenticated) { _ in
                HTTPResponse(
                    status: HTTPStatus.ok.rawValue,
                    headers: ["content-type": "text/plain; version=0.0.4; charset=utf-8"],
                    body: Data((await metrics.prometheusText()).utf8)
                )
            }
        }
    }
}

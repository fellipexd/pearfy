import Foundation
import PearfyContext

public struct JobSnapshot: Sendable, Equatable {
    public let name: String
    public let executions: Int
    public let failures: Int
    public let lastFailure: String?
}

public enum JobSchedulerError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidName
    case invalidInterval
    case duplicateJob(String)
    case maximumJobs(Int)

    public var description: String {
        switch self {
        case .invalidName: "PEARFY_JOB_001: job name must not be empty"
        case .invalidInterval: "PEARFY_JOB_002: fixed-delay interval must be positive"
        case .duplicateJob(let name): "PEARFY_JOB_003: job already scheduled: \(name)"
        case .maximumJobs(let maximum): "PEARFY_JOB_004: maximum scheduled jobs is \(maximum)"
        }
    }
}

/// Local, cooperative fixed-delay scheduler. It does not provide cluster-wide
/// exclusivity, cron semantics, persistence, or distributed checkpoints.
public actor JobScheduler: ApplicationLifecycle {
    private struct Definition: Sendable {
        let interval: Duration
        let handler: @Sendable () async throws -> Void
    }

    private var definitions: [String: Definition] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var executionCounts: [String: Int] = [:]
    private var failureCounts: [String: Int] = [:]
    private var lastFailures: [String: String] = [:]
    private var started = false
    private let maximumJobs: Int

    public nonisolated let name = "Pearfy job scheduler"

    public init(maximumJobs: Int = 256) {
        self.maximumJobs = max(1, maximumJobs)
    }

    public func schedule(
        _ name: String,
        every interval: Duration,
        handler: @escaping @Sendable () async throws -> Void
    ) throws {
        guard !name.isEmpty, name.utf8.count <= 128,
              name.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
              }) else {
            throw JobSchedulerError.invalidName
        }
        guard interval > .zero else { throw JobSchedulerError.invalidInterval }
        guard definitions[name] == nil else { throw JobSchedulerError.duplicateJob(name) }
        guard definitions.count < maximumJobs else { throw JobSchedulerError.maximumJobs(maximumJobs) }
        definitions[name] = Definition(interval: interval, handler: handler)
        if started { launch(name) }
    }

    public func start() async throws {
        guard !started else { return }
        started = true
        for name in definitions.keys.sorted() { launch(name) }
    }

    public func stop() async throws {
        guard started else { return }
        started = false
        let runningTasks = Array(tasks.values)
        tasks.removeAll()
        runningTasks.forEach { $0.cancel() }
        for task in runningTasks { await task.value }
    }

    public func snapshot() -> [JobSnapshot] {
        definitions.keys.sorted().map { name in
            JobSnapshot(
                name: name,
                executions: executionCounts[name, default: 0],
                failures: failureCounts[name, default: 0],
                lastFailure: lastFailures[name]
            )
        }
    }

    private func launch(_ name: String) {
        guard tasks[name] == nil, let definition = definitions[name] else { return }
        tasks[name] = Task { [weak self] in
            await self?.runLoop(name, definition: definition)
        }
    }

    private func runLoop(_ name: String, definition: Definition) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: definition.interval)
                try Task.checkCancellation()
            } catch {
                break
            }
            executionCounts[name, default: 0] += 1
            do {
                try await definition.handler()
                lastFailures.removeValue(forKey: name)
            } catch is CancellationError {
                break
            } catch {
                failureCounts[name, default: 0] += 1
                lastFailures[name] = String(reflecting: type(of: error))
            }
        }
        tasks.removeValue(forKey: name)
    }
}

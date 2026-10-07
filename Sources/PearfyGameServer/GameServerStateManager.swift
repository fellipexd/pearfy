import Foundation

/// Safe, explicitly allowlisted state record. `payload` must be a game-state projection,
/// never a ticket, credential, socket, request, or SQL binding.
public struct GameServerStateRecord: Codable, Sendable, Equatable, Identifiable {
    public let namespace: String
    public let key: String
    public let revision: UInt64
    public let updatedAt: Date
    public let payload: Data
    public var id: String { "\(namespace)/\(key)" }

    public init(namespace: String, key: String, revision: UInt64, updatedAt: Date = Date(), payload: Data) throws {
        guard Self.validIdentifier(namespace), Self.validIdentifier(key), payload.count <= 1_048_576 else {
            throw GameServerStateManagerError.invalidRecord
        }
        self.namespace = namespace; self.key = key; self.revision = revision; self.updatedAt = updatedAt; self.payload = payload
    }

    private enum CodingKeys: String, CodingKey { case namespace, key, revision, updatedAt, payload }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            namespace: container.decode(String.self, forKey: .namespace),
            key: container.decode(String.self, forKey: .key),
            revision: container.decode(UInt64.self, forKey: .revision),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            payload: container.decode(Data.self, forKey: .payload)
        )
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}

public protocol GameServerStateMiddleware: Sendable {
    /// Called on a dedicated asynchronous worker, never on a simulation/tick task.
    func persist(_ record: GameServerStateRecord) async throws
    func flush() async throws
}

/// Optional startup hydration contract for a recovery middleware. Recovery is awaited
/// during process startup, before the manager begins accepting game-state publications.
public protocol GameServerStateRestoringMiddleware: GameServerStateMiddleware {
    func restoreRecords() async throws -> [GameServerStateRecord]
}

/// Adapter for application-owned persistence (for example PearfyPostgres). Work runs on
/// a dedicated bounded worker; closures must use their own bounded connection pool.
public struct GameServerStateClosureMiddleware: GameServerStateMiddleware {
    private let write: @Sendable (GameServerStateRecord) async throws -> Void
    private let finish: @Sendable () async throws -> Void
    public init(
        persist: @escaping @Sendable (GameServerStateRecord) async throws -> Void,
        flush: @escaping @Sendable () async throws -> Void = {}
    ) { self.write = persist; self.finish = flush }
    public func persist(_ record: GameServerStateRecord) async throws { try await write(record) }
    public func flush() async throws { try await finish() }
}

public enum GameServerStatePublishResult: Sendable, Equatable { case enqueued, replacedOlder, unavailable }

/// Lock-backed mailbox with both item and byte ceilings. The producer only performs a
/// short in-memory operation; persistence remains on a separate async worker.
final class GameServerStateMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumItems: Int
    private let maximumBytes: Int
    private var records: [GameServerStateRecord] = []
    private var head = 0
    private var pendingBytes = 0
    private var finished = false
    private var waiter: CheckedContinuation<GameServerStateRecord?, Never>?

    init(maximumItems: Int, maximumBytes: Int) {
        self.maximumItems = maximumItems
        self.maximumBytes = maximumBytes
    }

    func enqueue(_ record: GameServerStateRecord) -> GameServerStatePublishResult {
        lock.lock()
        guard !finished, record.payload.count <= maximumBytes else {
            lock.unlock()
            return .unavailable
        }

        var replaced = false
        while pendingCount >= maximumItems || pendingBytes > maximumBytes - record.payload.count {
            guard head < records.count else {
                lock.unlock()
                return .unavailable
            }
            pendingBytes -= records[head].payload.count
            head += 1
            replaced = true
        }
        compactIfNeeded()
        records.append(record)
        pendingBytes += record.payload.count

        let continuation = waiter
        let next = continuation == nil ? nil : dequeue()
        if continuation != nil { waiter = nil }
        lock.unlock()
        if let continuation { continuation.resume(returning: next) }
        return replaced ? .replacedOlder : .enqueued
    }

    func next() async -> GameServerStateRecord? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let record = dequeue() {
                lock.unlock()
                continuation.resume(returning: record)
            } else if finished {
                lock.unlock()
                continuation.resume(returning: nil)
            } else if waiter == nil {
                waiter = continuation
                lock.unlock()
            } else {
                // Mailboxes have exactly one consumer; fail closed if that invariant changes.
                lock.unlock()
                continuation.resume(returning: nil)
            }
        }
    }

    func finish() {
        lock.lock()
        finished = true
        let continuation = pendingCount == 0 ? waiter : nil
        if continuation != nil { waiter = nil }
        lock.unlock()
        continuation?.resume(returning: nil)
    }

    private var pendingCount: Int { records.count - head }

    /// Caller holds `lock`.
    private func dequeue() -> GameServerStateRecord? {
        guard head < records.count else { return nil }
        let record = records[head]
        head += 1
        pendingBytes -= record.payload.count
        compactIfNeeded()
        return record
    }

    /// Caller holds `lock`.
    private func compactIfNeeded() {
        if head > 256 && head * 2 >= records.count {
            records.removeFirst(head)
            head = 0
        }
    }
}

/// Nonblocking ingress backed by a bounded mailbox. Publishing performs no I/O and
/// never waits for Redis, SQL, or dashboard work. Full buffers replace their oldest item.
public struct GameServerStatePublisher: Sendable {
    private let mailbox: GameServerStateMailbox
    private let ingressDrops: GameServerStateIngressDropCounter
    fileprivate init(_ mailbox: GameServerStateMailbox, ingressDrops: GameServerStateIngressDropCounter) {
        self.mailbox = mailbox; self.ingressDrops = ingressDrops
    }
    @discardableResult public func publish(_ record: GameServerStateRecord) -> GameServerStatePublishResult {
        switch mailbox.enqueue(record) {
        case .enqueued: return .enqueued
        case .replacedOlder:
            ingressDrops.increment()
            return .replacedOlder
        case .unavailable: return .unavailable
        }
    }
}

fileprivate final class GameServerStateIngressDropCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func increment() { lock.lock(); value &+= 1; lock.unlock() }
    func count() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
}

public struct GameServerStateManagerMetrics: Sendable, Equatable {
    public let retainedStateCount: Int
    public let retainedStateBytes: Int
    public let publishedStateCount: UInt64
    public let droppedOrReplacedCount: UInt64
    public let middlewareFailureCount: UInt64
    public let activeMiddlewareCount: Int
}

public struct GameServerStateRetryPolicy: Sendable, Equatable {
    public let maximumRetries: Int
    public let initialBackoffMilliseconds: Int64
    public let maximumBackoffMilliseconds: Int64
    public static let standard = GameServerStateRetryPolicy(maximumRetries: 3, initialBackoffMilliseconds: 25, maximumBackoffMilliseconds: 1_000, standard: ())
    public init(maximumRetries: Int = 3, initialBackoffMilliseconds: Int64 = 25, maximumBackoffMilliseconds: Int64 = 1_000) throws {
        guard (0...10).contains(maximumRetries), (1...60_000).contains(initialBackoffMilliseconds),
              initialBackoffMilliseconds <= maximumBackoffMilliseconds, maximumBackoffMilliseconds <= 300_000 else {
            throw GameServerStateManagerError.invalidConfiguration
        }
        self.maximumRetries = maximumRetries; self.initialBackoffMilliseconds = initialBackoffMilliseconds
        self.maximumBackoffMilliseconds = maximumBackoffMilliseconds
    }
    private init(maximumRetries: Int, initialBackoffMilliseconds: Int64, maximumBackoffMilliseconds: Int64, standard: Void) {
        self.maximumRetries = maximumRetries; self.initialBackoffMilliseconds = initialBackoffMilliseconds
        self.maximumBackoffMilliseconds = maximumBackoffMilliseconds
    }
}

public enum GameServerStateManagerError: Error, Sendable, Equatable {
    case invalidConfiguration, invalidRecord, alreadyConfigured
}

/// Process-wide state registry and asynchronous middleware coordinator. The singleton is
/// convenient for app composition; tests and isolated servers may construct their own.
public actor GameServerStateManager {
    public static let shared = GameServerStateManager()

    private struct MiddlewareWorker: Sendable {
        let middleware: any GameServerStateMiddleware
        let mailbox: GameServerStateMailbox
        let task: Task<Void, Never>
    }

    private let maximumRetainedStates: Int
    private let maximumPendingUpdates: Int
    private var inputMailbox: GameServerStateMailbox?
    private var inputTask: Task<Void, Never>?
    private var middlewareWorkers: [MiddlewareWorker] = []
    private var currentStates: [String: GameServerStateRecord] = [:]
    private var order: [String] = []
    private var published: UInt64 = 0
    private var dropped: UInt64 = 0
    private let ingressDrops = GameServerStateIngressDropCounter()
    private var middlewareFailures: UInt64 = 0
    private var isStopping = false
    private var isRestoring = false
    private var restoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownTask: Task<Void, Never>?

    private let maximumRetainedStateBytes: Int
    private var retainedStateBytes = 0

    public init(
        maximumRetainedStates: Int = 10_000,
        maximumPendingUpdates: Int = 1_024,
        maximumPendingStateBytes: Int = 1_048_576,
        maximumRetainedStateBytes: Int = 67_108_864
    ) {
        self.maximumRetainedStates = min(1_000_000, max(1, maximumRetainedStates))
        self.maximumPendingUpdates = min(1_000_000, max(1, maximumPendingUpdates))
        self.maximumPendingStateBytes = min(1_073_741_824, max(1_048_576, maximumPendingStateBytes))
        self.maximumRetainedStateBytes = min(1_073_741_824, max(1_048_576, maximumRetainedStateBytes))
    }

    private let maximumPendingStateBytes: Int

    /// Starts once. Each middleware gets a separate byte- and item-bounded mailbox and
    /// worker so a slow sink cannot stall the gameplay producer or other sinks.
    public func start(
        middlewares: [any GameServerStateMiddleware] = [],
        retryPolicy: GameServerStateRetryPolicy = .standard
    ) throws {
        guard !isStopping, !isRestoring else { throw GameServerStateManagerError.alreadyConfigured }
        guard inputMailbox == nil else { throw GameServerStateManagerError.alreadyConfigured }
        guard middlewares.count <= 64 else { throw GameServerStateManagerError.invalidConfiguration }
        let inputMailbox = GameServerStateMailbox(maximumItems: maximumPendingUpdates, maximumBytes: maximumPendingStateBytes)
        self.inputMailbox = inputMailbox
        for middleware in middlewares {
            let mailbox = GameServerStateMailbox(maximumItems: maximumPendingUpdates, maximumBytes: maximumPendingStateBytes)
            let task = Task { [weak self] in
                while let record = await mailbox.next() {
                    var persisted = false
                    var delay = retryPolicy.initialBackoffMilliseconds
                    for attempt in 0...retryPolicy.maximumRetries {
                        do { try await middleware.persist(record); persisted = true; break }
                        catch {
                            guard attempt < retryPolicy.maximumRetries else { break }
                            try? await Task.sleep(for: .milliseconds(delay))
                            delay = min(retryPolicy.maximumBackoffMilliseconds, delay > retryPolicy.maximumBackoffMilliseconds / 2
                                ? retryPolicy.maximumBackoffMilliseconds : delay * 2)
                        }
                    }
                    if !persisted { await self?.recordMiddlewareFailure() }
                }
                do { try await middleware.flush() }
                catch { await self?.recordMiddlewareFailure() }
            }
            middlewareWorkers.append(MiddlewareWorker(middleware: middleware, mailbox: mailbox, task: task))
        }
        inputTask = Task { [weak self] in
            while let record = await inputMailbox.next() { await self?.consume(record) }
        }
    }

    /// Hydrates from the recovery middleware, then starts all sinks. This async work is
    /// intended for startup and is never performed from a simulation or game tick.
    public func start(
        restoringFrom recovery: any GameServerStateRestoringMiddleware,
        middlewares: [any GameServerStateMiddleware] = [],
        retryPolicy: GameServerStateRetryPolicy = .standard
    ) async throws {
        guard !isStopping, !isRestoring, inputMailbox == nil, inputTask == nil else {
            throw GameServerStateManagerError.alreadyConfigured
        }
        isRestoring = true
        do {
            let records = try await recovery.restoreRecords()
            try replaceRestoredRecords(records)
            isRestoring = false
            try start(middlewares: [recovery] + middlewares, retryPolicy: retryPolicy)
            finishRestore()
        } catch {
            isRestoring = false
            finishRestore()
            throw error
        }
    }

    public func publisher() throws -> GameServerStatePublisher {
        guard let inputMailbox else { throw GameServerStateManagerError.invalidConfiguration }
        return GameServerStatePublisher(inputMailbox, ingressDrops: ingressDrops)
    }

    public func snapshot() -> [GameServerStateRecord] {
        order.compactMap { currentStates[$0] }
    }

    public func snapshot(offset: Int, limit: Int) -> (total: Int, records: [GameServerStateRecord]) {
        let boundedOffset = max(0, offset)
        let boundedLimit = min(100, max(1, limit))
        let total = order.count
        guard boundedOffset < total else { return (total, []) }
        let end = min(total, boundedOffset + boundedLimit)
        let records = order[boundedOffset..<end].compactMap { currentStates[$0] }
        return (total, records)
    }

    /// Loads a trusted recovery snapshot before start. Newer records for the same key win.
    public func restore(_ records: [GameServerStateRecord]) throws {
        guard !isStopping, !isRestoring, inputMailbox == nil, inputTask == nil else {
            throw GameServerStateManagerError.invalidConfiguration
        }
        try replaceRestoredRecords(records)
    }

    private func replaceRestoredRecords(_ records: [GameServerStateRecord]) throws {
        guard records.count <= 1_000_000 else { throw GameServerStateManagerError.invalidConfiguration }
        var latestByID: [String: GameServerStateRecord] = [:]
        for record in records {
            if let existing = latestByID[record.id],
               existing.revision > record.revision ||
                (existing.revision == record.revision && existing.updatedAt >= record.updatedAt) {
                continue
            }
            latestByID[record.id] = record
        }
        guard latestByID.count <= maximumRetainedStates else {
            throw GameServerStateManagerError.invalidConfiguration
        }
        var restoredStates: [String: GameServerStateRecord] = [:]
        var restoredOrder: [String] = []
        var restoredBytes = 0
        for record in latestByID.values.sorted(by: {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt < $1.updatedAt
        }) {
            guard record.payload.count <= maximumRetainedStateBytes,
                  restoredBytes <= maximumRetainedStateBytes - record.payload.count else {
                throw GameServerStateManagerError.invalidConfiguration
            }
            restoredOrder.append(record.id)
            restoredStates[record.id] = record
            restoredBytes += record.payload.count
        }
        currentStates = restoredStates
        order = restoredOrder
        retainedStateBytes = restoredBytes
    }

    public func metrics() -> GameServerStateManagerMetrics {
        GameServerStateManagerMetrics(retainedStateCount: currentStates.count, retainedStateBytes: retainedStateBytes, publishedStateCount: published,
                                      droppedOrReplacedCount: dropped &+ ingressDrops.count(), middlewareFailureCount: middlewareFailures,
                                      activeMiddlewareCount: middlewareWorkers.count)
    }

    public func stop() async {
        if isRestoring {
            await withCheckedContinuation { restoreWaiters.append($0) }
            await stop()
            return
        }
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard inputMailbox != nil || inputTask != nil || !middlewareWorkers.isEmpty else { return }
        isStopping = true
        let inputMailbox = self.inputMailbox
        let inputTask = self.inputTask
        let workers = middlewareWorkers
        self.inputMailbox = nil
        let shutdownTask = Task {
            inputMailbox?.finish()
            if let inputTask { await inputTask.value }
            workers.forEach { $0.mailbox.finish() }
            for worker in workers { await worker.task.value }
        }
        self.shutdownTask = shutdownTask
        await shutdownTask.value
        self.inputTask = nil
        middlewareWorkers.removeAll()
        self.shutdownTask = nil
        isStopping = false
    }

    private func consume(_ record: GameServerStateRecord) {
        if let current = currentStates[record.id], current.revision >= record.revision { return }
        published &+= 1
        if let previous = currentStates.removeValue(forKey: record.id) {
            retainedStateBytes -= previous.payload.count
            order.removeAll { $0 == record.id }; order.append(record.id)
        } else {
            order.append(record.id)
        }
        while currentStates.count >= maximumRetainedStates || retainedStateBytes > maximumRetainedStateBytes - record.payload.count {
            guard let oldest = order.first else { break }
            order.removeFirst()
            if let removed = currentStates.removeValue(forKey: oldest) { retainedStateBytes -= removed.payload.count; dropped &+= 1 }
        }
        currentStates[record.id] = record
        retainedStateBytes += record.payload.count
        for worker in middlewareWorkers {
            if worker.mailbox.enqueue(record) == .replacedOlder { dropped &+= 1 }
        }
    }

    private func recordMiddlewareFailure() { middlewareFailures &+= 1 }

    private func finishRestore() {
        let waiters = restoreWaiters
        restoreWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

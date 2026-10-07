import Foundation
import PearfyGameServer

/// Hard limits for synchronous tick staging before the separate Redis writer.
public struct RedisDurableGameTickWriteAheadBridgeConfiguration: Sendable, Equatable {
    public let maximumPendingBatches: Int
    public let maximumPendingBytes: Int

    public static let standard = RedisDurableGameTickWriteAheadBridgeConfiguration(
        maximumPendingBatches: 32,
        maximumPendingBytes: 16_777_216,
        standard: ()
    )

    public init(maximumPendingBatches: Int = 32, maximumPendingBytes: Int = 16_777_216) throws {
        guard (1...100_000).contains(maximumPendingBatches),
              (1...268_435_456).contains(maximumPendingBytes) else {
            throw RedisGameStateRecoveryError.invalidConfiguration
        }
        self.maximumPendingBatches = maximumPendingBatches
        self.maximumPendingBytes = maximumPendingBytes
    }

    private init(maximumPendingBatches: Int, maximumPendingBytes: Int, standard: Void) {
        self.maximumPendingBatches = maximumPendingBatches
        self.maximumPendingBytes = maximumPendingBytes
    }
}

/// Fixed-cardinality pressure and writer status; no session IDs or game payloads.
public struct RedisDurableGameTickWriteAheadBridgeMetrics: Sendable, Equatable {
    public let pendingBatchCount: Int
    public let pendingTickCount: Int
    public let pendingBytes: Int
    public let acceptedBatchCount: UInt64
    public let acceptedTickCount: UInt64
    public let committedBatchCount: UInt64
    public let committedTickCount: UInt64
    public let rejectedBatchCount: UInt64
    public let writerFailureCount: UInt64
    public let lastCommittedTick: UInt64
    public let isAcceptingBatches: Bool
    public let isWriterRunning: Bool
    public let isWriterFailed: Bool
    public let isTerminated: Bool
}

/// Synchronous bounded staging plus a separate async Redis write-ahead worker.
/// Stage batches from a fixed-step callback; only `onDurableCommit` may publish
/// their state. A failed append retains its exact batch and closes staging.
public final class RedisDurableGameTickWriteAheadBridge: @unchecked Sendable {
    public typealias CommitHandler = @Sendable (
        _ batchID: UUID,
        _ receipt: RedisDurableGameTickReceipt
    ) async throws -> Void
    public typealias FailureHandler = @Sendable () async -> Void

    private let ingress: RedisDurableGameTickWriteAheadIngress
    private let writer: RedisDurableGameTickWriteAheadWorker

    public init(
        session: RedisDurableGameTickSession,
        initialCommittedTick: UInt64,
        configuration: RedisDurableGameTickConfiguration = .standard,
        bridgeConfiguration: RedisDurableGameTickWriteAheadBridgeConfiguration = .standard,
        onDurableCommit: @escaping CommitHandler = { _, _ in },
        onWriterFailure: @escaping FailureHandler = {}
    ) {
        let ingress = RedisDurableGameTickWriteAheadIngress(
            initialCommittedTick: initialCommittedTick,
            configuration: configuration,
            bridgeConfiguration: bridgeConfiguration
        )
        self.ingress = ingress
        self.writer = RedisDurableGameTickWriteAheadWorker(
            session: session,
            ingress: ingress,
            onDurableCommit: onDurableCommit,
            onWriterFailure: onWriterFailure
        )
    }

    /// Stages without actor hopping or storage I/O. The handler should throw this
    /// error through `GameRealtimeFixedStepDriver` to close simulation admission.
    public func stage(_ batch: RedisDurableGameTickBatch) throws {
        try ingress.stage(batch)
    }

    public func metrics() -> RedisDurableGameTickWriteAheadBridgeMetrics {
        ingress.metrics()
    }

    /// Starts one serial background writer. Batches may be staged before start.
    @discardableResult
    public func start() async -> Bool {
        await writer.start()
    }

    /// Retries the same failed head batch after the application decides storage is
    /// available. Admission remains closed; rebuild simulation from committed state.
    @discardableResult
    public func retryPending() async -> Bool {
        await writer.retryPending()
    }

    /// Closes staging, finishes the notification stream and waits for an active
    /// writer to drain. A failed writer leaves pending batches visible in metrics.
    public func stop() async -> RedisDurableGameTickWriteAheadBridgeMetrics {
        await writer.stop()
    }
}

private struct RedisDurableGameTickWriteAheadPending: Sendable {
    let batch: RedisDurableGameTickBatch
    let retainedBytes: Int
}

/// Lock-protected source of truth; the AsyncStream only coalesces wake-ups.
private final class RedisDurableGameTickWriteAheadIngress: @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: RedisDurableGameTickConfiguration
    private let bridgeConfiguration: RedisDurableGameTickWriteAheadBridgeConfiguration
    private let notificationStream: AsyncStream<Void>
    private let notificationContinuation: AsyncStream<Void>.Continuation
    private var pending: [RedisDurableGameTickWriteAheadPending] = []
    private var pendingIDs: Set<UUID> = []
    private var inFlight: RedisDurableGameTickWriteAheadPending?
    private var pendingBytes = 0
    private var pendingTicks = 0
    private var lastStagedTick: UInt64
    private var lastCommittedTick: UInt64
    private var acceptedBatchCount: UInt64 = 0
    private var acceptedTickCount: UInt64 = 0
    private var committedBatchCount: UInt64 = 0
    private var committedTickCount: UInt64 = 0
    private var rejectedBatchCount: UInt64 = 0
    private var writerFailureCount: UInt64 = 0
    private var accepting = true
    private var writerRunning = false
    private var writerFailed = false
    private var terminated = false

    init(
        initialCommittedTick: UInt64,
        configuration: RedisDurableGameTickConfiguration,
        bridgeConfiguration: RedisDurableGameTickWriteAheadBridgeConfiguration
    ) {
        self.configuration = configuration
        self.bridgeConfiguration = bridgeConfiguration
        self.lastStagedTick = initialCommittedTick
        self.lastCommittedTick = initialCommittedTick
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.notificationStream = stream
        self.notificationContinuation = continuation
    }

    var notifications: AsyncStream<Void> { notificationStream }

    func stage(_ batch: RedisDurableGameTickBatch) throws {
        let bytes: Int
        do {
            try RedisDurableGameTickSession.validateBatch(batch, configuration: configuration)
            bytes = try RedisDurableGameTickSession.retainedByteEstimate(for: batch)
        } catch {
            lock.lock()
            rejectAndClose()
            lock.unlock()
            throw error
        }

        lock.lock()
        defer { lock.unlock() }
        guard accepting, !terminated else {
            rejectAndClose()
            throw RedisGameStateRecoveryError.tickQueueCapacityReached
        }
        guard !pendingIDs.contains(batch.id) else {
            rejectAndClose()
            throw RedisGameStateRecoveryError.tickBatchAlreadyQueued
        }
        guard lastStagedTick < .max,
              let firstTick = batch.ticks.first,
              firstTick.number == lastStagedTick + 1 else {
            let expected = lastStagedTick == .max ? UInt64.max : lastStagedTick + 1
            rejectAndClose()
            throw RedisGameStateRecoveryError.tickSequenceConflict(
                expected: expected,
                actual: batch.ticks.first?.number ?? 0
            )
        }
        let (nextBytes, overflow) = pendingBytes.addingReportingOverflow(bytes)
        let uncommittedBatchCount = pending.count + (inFlight == nil ? 0 : 1)
        guard uncommittedBatchCount < bridgeConfiguration.maximumPendingBatches,
              bytes <= bridgeConfiguration.maximumPendingBytes,
              !overflow, nextBytes <= bridgeConfiguration.maximumPendingBytes else {
            rejectAndClose()
            throw RedisGameStateRecoveryError.tickQueueCapacityReached
        }

        pending.append(RedisDurableGameTickWriteAheadPending(batch: batch, retainedBytes: bytes))
        pendingIDs.insert(batch.id)
        pendingBytes = nextBytes
        pendingTicks += batch.ticks.count
        lastStagedTick = batch.ticks[batch.ticks.count - 1].number
        if acceptedBatchCount < .max { acceptedBatchCount += 1 }
        let (nextTickCount, tickOverflow) = acceptedTickCount.addingReportingOverflow(UInt64(batch.ticks.count))
        acceptedTickCount = tickOverflow ? .max : nextTickCount
        notificationContinuation.yield(())
    }

    func takeNextBatch() -> RedisDurableGameTickWriteAheadPending? {
        lock.lock()
        defer { lock.unlock() }
        if let inFlight { return inFlight }
        guard !pending.isEmpty else { return nil }
        let next = pending.removeFirst()
        inFlight = next
        return next
    }

    func complete(batchID: UUID, receipt: RedisDurableGameTickReceipt) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let inFlight, inFlight.batch.id == batchID else {
            return false
        }
        pendingIDs.remove(batchID)
        pendingBytes -= inFlight.retainedBytes
        pendingTicks -= inFlight.batch.ticks.count
        lastCommittedTick = receipt.lastCommittedTick
        if committedBatchCount < .max { committedBatchCount += 1 }
        let (nextTickCount, overflow) = committedTickCount.addingReportingOverflow(UInt64(inFlight.batch.ticks.count))
        committedTickCount = overflow ? .max : nextTickCount
        self.inFlight = nil
        return true
    }

    func markWriterStarted() {
        lock.lock()
        writerRunning = true
        lock.unlock()
    }

    func markWriterStopped(failed: Bool = false) {
        lock.lock()
        writerRunning = false
        if failed {
            writerFailed = true
            accepting = false
            if writerFailureCount < .max { writerFailureCount += 1 }
        }
        lock.unlock()
    }

    func prepareRetry() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard writerFailed, !terminated, inFlight != nil || !pending.isEmpty else { return false }
        writerFailed = false
        writerRunning = true
        return true
    }

    func notifyPending() {
        lock.lock()
        let hasWork = inFlight != nil || !pending.isEmpty
        lock.unlock()
        if hasWork { notificationContinuation.yield(()) }
    }

    func closeAndFinish() {
        lock.lock()
        accepting = false
        terminated = true
        lock.unlock()
        notificationContinuation.finish()
    }

    func metrics() -> RedisDurableGameTickWriteAheadBridgeMetrics {
        lock.lock()
        defer { lock.unlock() }
        return RedisDurableGameTickWriteAheadBridgeMetrics(
            pendingBatchCount: pending.count + (inFlight == nil ? 0 : 1),
            pendingTickCount: pendingTicks,
            pendingBytes: pendingBytes,
            acceptedBatchCount: acceptedBatchCount,
            acceptedTickCount: acceptedTickCount,
            committedBatchCount: committedBatchCount,
            committedTickCount: committedTickCount,
            rejectedBatchCount: rejectedBatchCount,
            writerFailureCount: writerFailureCount,
            lastCommittedTick: lastCommittedTick,
            isAcceptingBatches: accepting,
            isWriterRunning: writerRunning,
            isWriterFailed: writerFailed,
            isTerminated: terminated
        )
    }

    private func rejectAndClose() {
        accepting = false
        if rejectedBatchCount < .max { rejectedBatchCount += 1 }
    }
}

private actor RedisDurableGameTickWriteAheadWorker {
    private let session: RedisDurableGameTickSession
    private let ingress: RedisDurableGameTickWriteAheadIngress
    private let onDurableCommit: RedisDurableGameTickWriteAheadBridge.CommitHandler
    private let onWriterFailure: RedisDurableGameTickWriteAheadBridge.FailureHandler
    private var task: Task<Void, Never>?

    init(
        session: RedisDurableGameTickSession,
        ingress: RedisDurableGameTickWriteAheadIngress,
        onDurableCommit: @escaping RedisDurableGameTickWriteAheadBridge.CommitHandler,
        onWriterFailure: @escaping RedisDurableGameTickWriteAheadBridge.FailureHandler
    ) {
        self.session = session
        self.ingress = ingress
        self.onDurableCommit = onDurableCommit
        self.onWriterFailure = onWriterFailure
    }

    func start() -> Bool {
        guard task == nil else { return false }
        let metrics = ingress.metrics()
        guard !metrics.isTerminated, !metrics.isWriterFailed else { return false }
        launch()
        return true
    }

    func retryPending() async -> Bool {
        if ingress.metrics().isWriterFailed, let task { await task.value }
        guard task == nil, ingress.prepareRetry() else { return false }
        launch()
        ingress.notifyPending()
        return true
    }

    func stop() async -> RedisDurableGameTickWriteAheadBridgeMetrics {
        ingress.closeAndFinish()
        if let task { await task.value }
        return ingress.metrics()
    }

    private func launch() {
        ingress.markWriterStarted()
        task = Task { await run() }
    }

    private func run() async {
        defer {
            ingress.markWriterStopped()
            task = nil
        }
        for await _ in ingress.notifications {
            while let pending = ingress.takeNextBatch() {
                do {
                    let receipt = try await session.commit(pending.batch)
                    guard let expectedTick = pending.batch.ticks.last?.number,
                          receipt.lastCommittedTick == expectedTick else {
                        throw RedisGameStateRecoveryError.tickSequenceConflict(
                            expected: pending.batch.ticks.last?.number ?? UInt64.max,
                            actual: receipt.lastCommittedTick
                        )
                    }
                    try await onDurableCommit(pending.batch.id, receipt)
                    guard ingress.complete(batchID: pending.batch.id, receipt: receipt) else {
                        throw RedisGameStateRecoveryError.invalidResponse
                    }
                } catch {
                    ingress.markWriterStopped(failed: true)
                    await onWriterFailure()
                    task = nil
                    return
                }
            }
        }
    }
}

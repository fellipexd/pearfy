import Foundation
@testable import PearfyGameServerRedisRecovery
import PearfyGameServer
import Testing

private actor DurableTickRecoveryStore: GameStateRecoveryStore {
    private var epoch: UInt64?
    private var checkpoint: GameStateCheckpoint?
    private var events: [GameStateEvent] = []
    private var failAfterNextAppend = false

    func failAfterNextAppendCommit() { failAfterNextAppend = true }

    func append(sessionID: UUID, epoch: UInt64, event: GameStateEvent) async throws {
        if let currentEpoch = self.epoch, currentEpoch != epoch { throw RedisGameStateRecoveryError.staleEpoch }
        let latest = events.last?.sequence ?? checkpoint?.revision ?? 0
        if event.sequence == latest, events.last == event { return }
        guard event.sequence == latest + 1 else { throw RedisGameStateRecoveryError.sequenceConflict }
        self.epoch = epoch
        events.append(event)
        if failAfterNextAppend {
            failAfterNextAppend = false
            throw RedisGameStateRecoveryError.journalUnavailable
        }
    }

    func save(sessionID: UUID, epoch: UInt64, checkpoint: GameStateCheckpoint) async throws {
        if let currentEpoch = self.epoch, currentEpoch != epoch { throw RedisGameStateRecoveryError.staleEpoch }
        let latest = events.last?.sequence ?? self.checkpoint?.revision ?? 0
        guard checkpoint.revision <= latest else { throw RedisGameStateRecoveryError.sequenceConflict }
        self.epoch = epoch
        self.checkpoint = checkpoint
        events.removeAll { $0.sequence <= checkpoint.revision }
    }

    func load(sessionID: UUID) async throws -> (epoch: UInt64, checkpoint: GameStateCheckpoint, events: [GameStateEvent], latestSequence: UInt64)? {
        guard let epoch, let checkpoint else { return nil }
        return (epoch, checkpoint, events, events.last?.sequence ?? checkpoint.revision)
    }

    func transfer(to epoch: UInt64) { self.epoch = epoch }
}

@Test func durableTickBatchesCommitOnceReplayMovementNPCAndRecordedRandomDraws() async throws {
    let sessionID = UUID()
    let store = DurableTickRecoveryStore()
    let lease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 1, durationMilliseconds: 30_000)
    let reducer: RedisDurableGameTickSession.AsyncReducer = { state, tick in
        var total = Int(String(decoding: state, as: UTF8.self)) ?? 0
        for transition in tick.transitions {
            let pieces = String(decoding: transition, as: UTF8.self).split(separator: ":")
            guard pieces.count == 2, let amount = Int(pieces[1]) else { throw GameServerError.invalidCheckpoint }
            total += amount
        }
        total += tick.randomDraws.reduce(0) { $0 + Int($1) }
        return Data(String(total).utf8)
    }
    let session = try await RedisDurableGameTickSession.open(
        sessionID: sessionID, lease: lease, store: store, initialState: Data("0".utf8), reducer: reducer
    )
    let firstBatch = RedisDurableGameTickBatch(ticks: [
        RedisDurableGameTick(number: 1, transitions: [Data("move:3".utf8), Data("npc:2".utf8)], randomDraws: [7]),
        RedisDurableGameTick(number: 2, transitions: [Data("move:4".utf8)]),
        RedisDurableGameTick(number: 3, transitions: [Data("timer:1".utf8)])
    ])
    let firstReceipt = try await session.commit(firstBatch, expectedRevision: 0)
    #expect(firstReceipt.revision == 1)
    #expect(firstReceipt.lastCommittedTick == 3)
    #expect(firstReceipt.state == Data("17".utf8))
    let duplicate = try await session.commit(firstBatch, expectedRevision: 0)
    #expect(duplicate.isDuplicate)
    #expect(duplicate.lastCommittedTick == 3)
    #expect(duplicate.state == Data("17".utf8))

    do {
        _ = try await session.commit(RedisDurableGameTickBatch(ticks: [
            RedisDurableGameTick(number: 5, transitions: [Data("move:2".utf8)])
        ]))
        Issue.record("a batch that skips tick 4 must be rejected")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .tickSequenceConflict(expected: 4, actual: 5))
    }
    #expect(await session.snapshot() == RedisDurableGameTickSnapshot(revision: 1, lastCommittedTick: 3, state: Data("17".utf8)))

    try await session.checkpoint()
    let secondBatch = RedisDurableGameTickBatch(ticks: [
        RedisDurableGameTick(number: 4, transitions: [Data("npc:2".utf8)], randomDraws: [3]),
        RedisDurableGameTick(number: 5, transitions: [Data("move:4".utf8)])
    ])
    _ = try await session.commit(secondBatch, expectedRevision: 1)

    await store.transfer(to: 2)
    let nextLease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 2, durationMilliseconds: 30_000)
    let recovered = try await RedisDurableGameTickSession.open(
        sessionID: sessionID, lease: nextLease, store: store, reducer: reducer
    )
    #expect(await recovered.snapshot() == RedisDurableGameTickSnapshot(
        revision: 2, lastCommittedTick: 5, state: Data("26".utf8)
    ))
    let oldRetry = try await recovered.commit(firstBatch)
    #expect(oldRetry.isDuplicate)
    #expect(oldRetry.lastCommittedTick == 5)
    #expect(oldRetry.state == Data("26".utf8))
}

@Test func durableTickBatchesRejectGapsAndPayloadsOutsideConfiguredBounds() async throws {
    let configuration = try RedisDurableGameTickConfiguration(
        maximumStateBytes: 1_024,
        maximumTransitionBytes: 2,
        maximumTransitionsPerTick: 1,
        maximumRandomDrawsPerTick: 1,
        maximumTicksPerBatch: 2,
        maximumTransitionsPerBatch: 2,
        maximumRandomDrawsPerBatch: 2,
        maximumBatchBytes: 2_048,
        maximumProcessedBatches: 1,
        maximumReplayBatches: 2,
        maximumCheckpointBytes: 4_096
    )
    let sessionID = UUID()
    let store = DurableTickRecoveryStore()
    let lease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 1, durationMilliseconds: 30_000)
    let session = try await RedisDurableGameTickSession.open(
        sessionID: sessionID,
        lease: lease,
        store: store,
        initialState: Data([0]),
        configuration: configuration,
        reducer: { state, _ in state }
    )

    await #expect(throws: RedisGameStateRecoveryError.recordTooLarge(maximumBytes: 2)) {
        _ = try await session.commit(RedisDurableGameTickBatch(ticks: [
            RedisDurableGameTick(number: 1, transitions: [Data([1, 2, 3])])
        ]))
    }
    await #expect(throws: RedisGameStateRecoveryError.tickBatchLimitExceeded) {
        _ = try await session.commit(RedisDurableGameTickBatch(ticks: []))
    }
}

@Test func durableTickQueueBoundsStagingAndRetriesAmbiguousHeadBeforeLaterBatches() async throws {
    let sessionID = UUID()
    let store = DurableTickRecoveryStore()
    let lease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 1, durationMilliseconds: 30_000)
    let session = try await RedisDurableGameTickSession.open(
        sessionID: sessionID,
        lease: lease,
        store: store,
        initialState: Data("0".utf8),
        reducer: { state, tick in
            let current = Int(String(decoding: state, as: UTF8.self)) ?? 0
            return Data(String(current + tick.transitions.count).utf8)
        }
    )
    let queue = try await session.makeBoundedQueue(maximumPendingBatches: 2, maximumPendingBytes: 2_048)
    let notifications = await queue.pendingBatchNotifications()
    var notificationIterator = notifications.makeAsyncIterator()
    let first = RedisDurableGameTickBatch(ticks: [
        RedisDurableGameTick(number: 1, transitions: [Data("move".utf8)])
    ])
    let second = RedisDurableGameTickBatch(ticks: [
        RedisDurableGameTick(number: 2, transitions: [Data("npc".utf8)])
    ])
    try await queue.stage(first)
    try await queue.stage(second)
    #expect(await notificationIterator.next() != nil)
    #expect(await queue.metrics().pendingBatchCount == 2)
    await #expect(throws: RedisGameStateRecoveryError.tickQueueCapacityReached) {
        try await queue.stage(RedisDurableGameTickBatch(ticks: [
            RedisDurableGameTick(number: 3, transitions: [Data("timer".utf8)])
        ]))
    }

    await store.failAfterNextAppendCommit()
    await #expect(throws: RedisGameStateRecoveryError.journalUnavailable) {
        _ = try await queue.commitNext()
    }
    #expect(await queue.metrics().pendingBatchCount == 2)
    #expect(await session.snapshot().lastCommittedTick == 0)
    #expect(try await queue.commitNext()?.lastCommittedTick == 1)
    #expect(try await queue.commitNext()?.lastCommittedTick == 2)
    #expect(try await queue.commitNext() == nil)
    #expect(await queue.metrics() == RedisDurableGameTickQueueMetrics(
        pendingBatchCount: 0, pendingBytes: 0, isCommitting: false
    ))
    #expect(await session.snapshot().state == Data("2".utf8))
}

@Test func durableTickWriteAheadBridgeStagesSynchronouslyAndCommitsOffTick() async throws {
    let sessionID = UUID()
    let store = DurableTickRecoveryStore()
    let lease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 1, durationMilliseconds: 30_000)
    let session = try await RedisDurableGameTickSession.open(
        sessionID: sessionID,
        lease: lease,
        store: store,
        initialState: Data("0".utf8),
        reducer: { state, tick in
            let current = Int(String(decoding: state, as: UTF8.self)) ?? 0
            return Data(String(current + tick.transitions.count).utf8)
        }
    )
    let (commits, commitContinuation) = AsyncStream<(UUID, RedisDurableGameTickReceipt)>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )
    let bridge = RedisDurableGameTickWriteAheadBridge(
        session: session,
        initialCommittedTick: 0,
        onDurableCommit: { batchID, receipt in commitContinuation.yield((batchID, receipt)) }
    )
    let batch = RedisDurableGameTickBatch(ticks: [
        RedisDurableGameTick(number: 1, transitions: [Data("move:3".utf8)])
    ])

    // This is deliberately synchronous so a fixed-step handler never actor-hops to Redis.
    try bridge.stage(batch)
    #expect(await session.snapshot().state == Data("0".utf8))
    #expect(bridge.metrics().pendingBatchCount == 1)
    #expect(bridge.metrics().lastCommittedTick == 0)

    var commitIterator = commits.makeAsyncIterator()
    #expect(await bridge.start())
    let committed = await commitIterator.next()
    #expect(committed?.0 == batch.id)
    #expect(committed?.1.state == Data("1".utf8))
    #expect(committed?.1.lastCommittedTick == 1)
    #expect(bridge.metrics().pendingBatchCount == 0)
    #expect(bridge.metrics().committedTickCount == 1)

    let stopped = await bridge.stop()
    commitContinuation.finish()
    #expect(stopped.isTerminated)
    #expect(stopped.pendingBytes == 0)
}

@Test func durableRealtimeDriverStagesToRedisBridgeFromRecoveredTickCursor() async throws {
    let sessionID = UUID()
    let store = DurableTickRecoveryStore()
    let lease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 1, durationMilliseconds: 30_000)
    let session = try await RedisDurableGameTickSession.open(
        sessionID: sessionID,
        lease: lease,
        store: store,
        initialState: Data("0".utf8),
        initialTick: 5,
        reducer: { state, tick in
            let value = Int(String(decoding: state, as: UTF8.self)) ?? 0
            return Data(String(value + tick.transitions.count).utf8)
        }
    )
    let simulation = try GameRealtimeSimulation(maximumQueuedInputs: 2, initialTick: 5)
    let (commits, continuation) = AsyncStream<RedisDurableGameTickReceipt>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )
    let bridge = RedisDurableGameTickWriteAheadBridge(
        session: session,
        initialCommittedTick: 5,
        onDurableCommit: { _, receipt in continuation.yield(receipt) }
    )
    let driver = GameRealtimeFixedStepDriver(
        simulation: simulation,
        configuration: try GameRealtimeFixedStepConfiguration(tickRateHz: 100, maximumInputsPerTick: 1)
    ) { tick in
        try bridge.stage(RedisDurableGameTickBatch(ticks: [
            RedisDurableGameTick(number: tick.tick, transitions: [Data([1])])
        ]))
    }

    var commitIterator = commits.makeAsyncIterator()
    #expect(await bridge.start())
    #expect(await driver.start())
    let firstReceipt = await commitIterator.next()
    #expect(firstReceipt?.lastCommittedTick == 6)
    #expect(firstReceipt?.state == Data("1".utf8))
    await driver.stop()
    let stopped = await bridge.stop()
    continuation.finish()
    #expect(stopped.pendingBatchCount == 0)
    #expect(stopped.lastCommittedTick >= 6)
}

@Test func durableTickWriteAheadBridgeClosesOnCapacityAndPreservesAcceptedBatches() async throws {
    let sessionID = UUID()
    let store = DurableTickRecoveryStore()
    let lease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 1, durationMilliseconds: 30_000)
    let session = try await RedisDurableGameTickSession.open(
        sessionID: sessionID,
        lease: lease,
        store: store,
        initialState: Data("0".utf8),
        reducer: { state, _ in Data(String((Int(String(decoding: state, as: UTF8.self)) ?? 0) + 1).utf8) }
    )
    let (commits, commitContinuation) = AsyncStream<RedisDurableGameTickReceipt>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )
    let bridge = RedisDurableGameTickWriteAheadBridge(
        session: session,
        initialCommittedTick: 0,
        bridgeConfiguration: try RedisDurableGameTickWriteAheadBridgeConfiguration(
            maximumPendingBatches: 1,
            maximumPendingBytes: 4_096
        ),
        onDurableCommit: { _, receipt in commitContinuation.yield(receipt) }
    )
    try bridge.stage(RedisDurableGameTickBatch(ticks: [
        RedisDurableGameTick(number: 1, transitions: [Data([1])])
    ]))
    do {
        try bridge.stage(RedisDurableGameTickBatch(ticks: [
            RedisDurableGameTick(number: 2, transitions: [Data([2])])
        ]))
        Issue.record("full write-ahead staging must reject and close admission")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .tickQueueCapacityReached)
    }
    #expect(bridge.metrics().pendingBatchCount == 1)
    #expect(!bridge.metrics().isAcceptingBatches)
    #expect(bridge.metrics().rejectedBatchCount == 1)

    var commitIterator = commits.makeAsyncIterator()
    #expect(await bridge.start())
    #expect(await commitIterator.next()?.lastCommittedTick == 1)
    let stopped = await bridge.stop()
    commitContinuation.finish()
    #expect(stopped.pendingBatchCount == 0)
    #expect(stopped.committedTickCount == 1)
}

@Test func durableTickWriteAheadBridgeRetriesAmbiguousAppendWithSameBatchID() async throws {
    let sessionID = UUID()
    let store = DurableTickRecoveryStore()
    let lease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 1, durationMilliseconds: 30_000)
    let session = try await RedisDurableGameTickSession.open(
        sessionID: sessionID,
        lease: lease,
        store: store,
        initialState: Data("0".utf8),
        reducer: { state, _ in Data(String((Int(String(decoding: state, as: UTF8.self)) ?? 0) + 1).utf8) }
    )
    let (commits, commitContinuation) = AsyncStream<(UUID, RedisDurableGameTickReceipt)>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )
    let (failures, failureContinuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let bridge = RedisDurableGameTickWriteAheadBridge(
        session: session,
        initialCommittedTick: 0,
        onDurableCommit: { batchID, receipt in commitContinuation.yield((batchID, receipt)) },
        onWriterFailure: { failureContinuation.yield(true) }
    )
    let batch = RedisDurableGameTickBatch(ticks: [
        RedisDurableGameTick(number: 1, transitions: [Data([1])])
    ])
    try bridge.stage(batch)
    await store.failAfterNextAppendCommit()
    var commitIterator = commits.makeAsyncIterator()
    var failureIterator = failures.makeAsyncIterator()

    #expect(await bridge.start())
    #expect(await failureIterator.next() == true)
    #expect(bridge.metrics().isWriterFailed)
    #expect(bridge.metrics().pendingBatchCount == 1)
    #expect(await session.snapshot().lastCommittedTick == 0)

    #expect(await bridge.retryPending())
    let committed = await commitIterator.next()
    #expect(committed?.0 == batch.id)
    #expect(committed?.1.state == Data("1".utf8))
    #expect(committed?.1.lastCommittedTick == 1)
    #expect(bridge.metrics().pendingBatchCount == 0)
    #expect(bridge.metrics().writerFailureCount == 1)

    _ = await bridge.stop()
    commitContinuation.finish()
    failureContinuation.finish()
}

@Test func durableTickWriteAheadBridgeRejectsPreviouslyCommittedBatchIDBeforePublish() async throws {
    let sessionID = UUID()
    let store = DurableTickRecoveryStore()
    let lease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 1, durationMilliseconds: 30_000)
    let session = try await RedisDurableGameTickSession.open(
        sessionID: sessionID,
        lease: lease,
        store: store,
        initialState: Data("0".utf8),
        reducer: { state, _ in Data(String((Int(String(decoding: state, as: UTF8.self)) ?? 0) + 1).utf8) }
    )
    let reusedBatchID = UUID()
    _ = try await session.commit(RedisDurableGameTickBatch(id: reusedBatchID, ticks: [
        RedisDurableGameTick(number: 1, transitions: [Data("first".utf8)])
    ]))

    let (published, publishContinuation) = AsyncStream<RedisDurableGameTickReceipt>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )
    let (failures, failureContinuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let bridge = RedisDurableGameTickWriteAheadBridge(
        session: session,
        initialCommittedTick: 1,
        onDurableCommit: { _, receipt in publishContinuation.yield(receipt) },
        onWriterFailure: { failureContinuation.yield(true) }
    )
    try bridge.stage(RedisDurableGameTickBatch(id: reusedBatchID, ticks: [
        RedisDurableGameTick(number: 2, transitions: [Data("second".utf8)])
    ]))

    var publishIterator = published.makeAsyncIterator()
    var failureIterator = failures.makeAsyncIterator()
    #expect(await bridge.start())
    #expect(await failureIterator.next() == true)
    #expect(bridge.metrics().isWriterFailed)
    #expect(bridge.metrics().pendingBatchCount == 1)
    #expect(bridge.metrics().committedBatchCount == 0)
    #expect(await session.snapshot().lastCommittedTick == 1)

    _ = await bridge.stop()
    publishContinuation.finish()
    failureContinuation.finish()
    #expect(await publishIterator.next() == nil)
}

@Test func durableTickBatchesRecoverWithRealRedisWhenConfigured() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_PORT"] ?? "6379") ?? 6379
    let configuration = try RedisGameStateRecoveryConfiguration(
        host: host, port: port, keyPrefix: "pearfy-durable-ticks-\(UUID().uuidString.lowercased())"
    )
    let store = RedisGameStateRecoveryStore(configuration: configuration)
    try await store.start()
    do {
        let sessionID = UUID()
        let lease = try await store.acquireLease(sessionID: sessionID)
        let reducer: RedisDurableGameTickSession.AsyncReducer = { state, tick in
            let value = Int(String(decoding: state, as: UTF8.self)) ?? 0
            return Data(String(value + tick.transitions.count + tick.randomDraws.reduce(0) { $0 + Int($1) }).utf8)
        }
        let session = try await RedisDurableGameTickSession.open(
            sessionID: sessionID, lease: lease, store: store, initialState: Data("0".utf8), reducer: reducer
        )
        let first = RedisDurableGameTickBatch(ticks: [
            RedisDurableGameTick(number: 1, transitions: [Data("move".utf8), Data("npc".utf8)], randomDraws: [5]),
            RedisDurableGameTick(number: 2, transitions: [Data("timer".utf8)])
        ])
        _ = try await session.commit(first)
        try await session.checkpoint()
        _ = try await session.commit(RedisDurableGameTickBatch(ticks: [
            RedisDurableGameTick(number: 3, transitions: [Data("move".utf8)], randomDraws: [2])
        ]))
        #expect(try await store.releaseLease(lease))

        let nextLease = try await store.acquireLease(sessionID: sessionID)
        let recovered = try await RedisDurableGameTickSession.open(
            sessionID: sessionID, lease: nextLease, store: store, reducer: reducer
        )
        #expect(await recovered.snapshot().lastCommittedTick == 3)
        #expect(await recovered.snapshot().state == Data("11".utf8))
        #expect(try await store.releaseLease(nextLease))
        try await store.stop()
    } catch {
        try? await store.stop()
        throw error
    }
}

@Test func durableTickWriteAheadBridgeCommitsAndRecoversWithRealRedisWhenConfigured() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_PORT"] ?? "6379") ?? 6379
    let configuration = try RedisGameStateRecoveryConfiguration(
        host: host, port: port, keyPrefix: "pearfy-tick-bridge-\(UUID().uuidString.lowercased())"
    )
    let store = RedisGameStateRecoveryStore(configuration: configuration)
    try await store.start()
    do {
        let sessionID = UUID()
        let lease = try await store.acquireLease(sessionID: sessionID)
        let reducer: RedisDurableGameTickSession.AsyncReducer = { state, tick in
            let value = Int(String(decoding: state, as: UTF8.self)) ?? 0
            return Data(String(value + tick.transitions.count + tick.randomDraws.reduce(0) { $0 + Int($1) }).utf8)
        }
        let session = try await RedisDurableGameTickSession.open(
            sessionID: sessionID,
            lease: lease,
            store: store,
            initialState: Data("0".utf8),
            initialTick: 10,
            reducer: reducer
        )
        let (commits, continuation) = AsyncStream<RedisDurableGameTickReceipt>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let bridge = RedisDurableGameTickWriteAheadBridge(
            session: session,
            initialCommittedTick: 10,
            onDurableCommit: { _, receipt in continuation.yield(receipt) }
        )
        try bridge.stage(RedisDurableGameTickBatch(ticks: [
            RedisDurableGameTick(number: 11, transitions: [Data("move".utf8)], randomDraws: [2]),
            RedisDurableGameTick(number: 12, transitions: [Data("npc".utf8)])
        ]))
        var iterator = commits.makeAsyncIterator()
        #expect(await bridge.start())
        let receipt = await iterator.next()
        #expect(receipt?.lastCommittedTick == 12)
        #expect(receipt?.state == Data("4".utf8))
        let bridgeMetrics = await bridge.stop()
        continuation.finish()
        #expect(bridgeMetrics.pendingBatchCount == 0)
        #expect(bridgeMetrics.committedBatchCount == 1)

        try await session.checkpoint()
        #expect(try await store.releaseLease(lease))
        let recoveredLease = try await store.acquireLease(sessionID: sessionID)
        let recovered = try await RedisDurableGameTickSession.open(
            sessionID: sessionID, lease: recoveredLease, store: store, reducer: reducer
        )
        #expect(await recovered.snapshot().lastCommittedTick == 12)
        #expect(await recovered.snapshot().state == Data("4".utf8))
        #expect(try await store.releaseLease(recoveredLease))
        try await store.stop()
    } catch {
        try? await store.stop()
        throw error
    }
}

@Test func durableCommandPayloadsFitTheConfiguredLimitAfterJSONBase64Encoding() async throws {
    let sessionID = UUID()
    let store = DurableTickRecoveryStore()
    let lease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 1, durationMilliseconds: 30_000)
    let configuration = try RedisDurableGameCommandConfiguration(
        maximumStateBytes: 1_024,
        maximumCommandBytes: 65_536,
        maximumProcessedCommands: 1,
        maximumReplayEvents: 4,
        maximumCheckpointBytes: 2_048
    )
    let session = try await RedisDurableGameCommandSession.open(
        sessionID: sessionID,
        lease: lease,
        store: store,
        initialState: Data("0".utf8),
        configuration: configuration,
        reducer: { _, _, command in Data(String(command.count).utf8) }
    )
    let largeCommand = Data(repeating: 7, count: 60_000)
    let receipt = try await session.commit(commandID: UUID(), playerID: UUID(), command: largeCommand)
    #expect(receipt.state == Data("60000".utf8))

    await store.transfer(to: 2)
    let nextLease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 2, durationMilliseconds: 30_000)
    let recovered = try await RedisDurableGameCommandSession.open(
        sessionID: sessionID,
        lease: nextLease,
        store: store,
        configuration: configuration,
        reducer: { _, _, command in Data(String(command.count).utf8) }
    )
    #expect(await recovered.snapshot() == (revision: 1, state: Data("60000".utf8)))
}

import Foundation
import PearfyGameServer
import PearfyGameServerTurnBased
import PearfyGameServerTurnBasedRedis
@testable import PearfyGameServerRedisRecovery
import Testing

private actor TurnBasedRecoveryRecorder: GameStateRecoveryStore {
    private var epoch: UInt64 = 1
    private var checkpoint: GameStateCheckpoint?
    private var suffix: [GameStateEvent] = []

    func append(sessionID: UUID, epoch: UInt64, event: GameStateEvent) async throws {
        guard epoch == self.epoch else { throw RedisGameStateRecoveryError.staleEpoch }
        let latest = (checkpoint?.revision ?? 0) + UInt64(suffix.count)
        if event.sequence == latest, suffix.last == event { return }
        guard event.sequence == latest + 1 else { throw RedisGameStateRecoveryError.sequenceConflict }
        suffix.append(event)
    }

    func save(sessionID: UUID, epoch: UInt64, checkpoint: GameStateCheckpoint) async throws {
        guard epoch == self.epoch else { throw RedisGameStateRecoveryError.staleEpoch }
        guard checkpoint.revision >= (self.checkpoint?.revision ?? 0) else {
            throw RedisGameStateRecoveryError.staleCheckpoint
        }
        self.checkpoint = checkpoint
        suffix.removeAll { $0.sequence <= checkpoint.revision }
    }

    func load(sessionID: UUID) async throws -> (epoch: UInt64, checkpoint: GameStateCheckpoint, events: [GameStateEvent], latestSequence: UInt64)? {
        guard let checkpoint else { return nil }
        return (epoch, checkpoint, suffix, checkpoint.revision + UInt64(suffix.count))
    }

    func transferLease(to epoch: UInt64) { self.epoch = epoch }
}

@Test func redisTurnBasedStoreAppendsCheckpointsAndReopensUnderNewFence() async throws {
    let sessionID = UUID()
    let playerID = UUID()
    let recorder = TurnBasedRecoveryRecorder()
    let firstLease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 1, durationMilliseconds: 30_000)
    let firstStore = try await RedisGameTurnBasedCommandStore.open(
        sessionID: sessionID, lease: firstLease, recoveryStore: recorder, initialState: Data("0".utf8)
    )
    let reducer: GameTurnBasedSession.Reducer = { state, _, command in
        guard let current = Int(String(decoding: state, as: UTF8.self)),
              let delta = Int(String(decoding: command, as: UTF8.self)), delta > 0 else {
            throw TurnBasedRedisTestError.invalidCommand
        }
        return Data(String(current + delta).utf8)
    }
    let session = try await GameTurnBasedSession.open(
        sessionID: sessionID, initialState: Data("0".utf8), store: firstStore, reducer: reducer
    )
    let commandID = UUID()
    _ = try await session.submit(commandID: commandID, playerID: playerID, command: Data("2".utf8))
    try await firstStore.saveCheckpoint()
    _ = try await session.submit(commandID: UUID(), playerID: playerID, command: Data("3".utf8))
    #expect(await session.currentState() == Data("5".utf8))
    do {
        _ = try await firstStore.append(
            sessionID: sessionID,
            expectedRevision: 0,
            event: GameStateEvent(sequence: 1, commandID: commandID, playerID: playerID, payload: Data("2".utf8), state: Data("2".utf8))
        )
        Issue.record("an old command retry must conflict after the session has advanced")
    } catch {
        #expect(error as? GameServerError == .revisionConflict(current: 2))
    }

    await recorder.transferLease(to: 2)
    let nextLease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 2, durationMilliseconds: 30_000)
    let reopenedStore = try await RedisGameTurnBasedCommandStore.open(
        sessionID: sessionID, lease: nextLease, recoveryStore: recorder, initialState: Data("0".utf8)
    )
    let reopened = try await GameTurnBasedSession.open(
        sessionID: sessionID, initialState: Data("0".utf8), store: reopenedStore, reducer: reducer
    )
    #expect(await reopened.currentRevision == 2)
    #expect(await reopened.currentState() == Data("5".utf8))
    let duplicate = try await reopened.submit(commandID: commandID, playerID: playerID, command: Data("2".utf8))
    if case .duplicate = duplicate { #expect(true) } else { Issue.record("retry must return the original event") }
}

@Test func redisTurnBasedStoreRejectsStaleEpochAndInvalidLimits() async throws {
    let sessionID = UUID()
    let recorder = TurnBasedRecoveryRecorder()
    let oldLease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 1, durationMilliseconds: 30_000)
    let store = try await RedisGameTurnBasedCommandStore.open(
        sessionID: sessionID, lease: oldLease, recoveryStore: recorder, initialState: Data("0".utf8)
    )
    await recorder.transferLease(to: 2)
    await #expect(throws: RedisGameStateRecoveryError.staleEpoch) {
        _ = try await store.load(sessionID: sessionID)
    }
    #expect(throws: RedisGameTurnBasedStoreError.invalidConfiguration) {
        try RedisGameTurnBasedConfiguration(maximumEvents: 0)
    }
}

@Test func redisTurnBasedStoreRecoversWithRealRedisWhenConfigured() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_PORT"] ?? "6379") ?? 6379
    let configuration = try RedisGameStateRecoveryConfiguration(
        host: host, port: port, keyPrefix: "pearfy-turn-based-redis-\(UUID().uuidString.lowercased())"
    )
    let recoveryStore = RedisGameStateRecoveryStore(configuration: configuration)
    try await recoveryStore.start()
    do {
        let sessionID = UUID()
        let playerID = UUID()
        let lease = try await recoveryStore.acquireLease(sessionID: sessionID)
        let commandStore = try await RedisGameTurnBasedCommandStore.open(
            sessionID: sessionID, lease: lease, recoveryStore: recoveryStore, initialState: Data("0".utf8)
        )
        let reducer: GameTurnBasedSession.Reducer = { state, _, command in
            let current = Int(String(decoding: state, as: UTF8.self)) ?? 0
            let delta = Int(String(decoding: command, as: UTF8.self)) ?? 0
            return Data(String(current + delta).utf8)
        }
        let session = try await GameTurnBasedSession.open(
            sessionID: sessionID, initialState: Data("0".utf8), store: commandStore, reducer: reducer
        )
        let commandID = UUID()
        _ = try await session.submit(commandID: commandID, playerID: playerID, command: Data("7".utf8))
        try await commandStore.saveCheckpoint()
        _ = try await session.submit(commandID: UUID(), playerID: playerID, command: Data("4".utf8))
        #expect(try await recoveryStore.releaseLease(lease))

        let nextLease = try await recoveryStore.acquireLease(sessionID: sessionID)
        #expect(nextLease.epoch == lease.epoch + 1)
        let recoveredStore = try await RedisGameTurnBasedCommandStore.open(
            sessionID: sessionID, lease: nextLease, recoveryStore: recoveryStore, initialState: Data("0".utf8)
        )
        let recovered = try await GameTurnBasedSession.open(
            sessionID: sessionID, initialState: Data("0".utf8), store: recoveredStore, reducer: reducer
        )
        #expect(await recovered.currentRevision == 2)
        #expect(await recovered.currentState() == Data("11".utf8))
        let duplicate = try await recovered.submit(commandID: commandID, playerID: playerID, command: Data("7".utf8))
        if case .duplicate = duplicate { #expect(true) } else { Issue.record("retry must return the original event") }
        #expect(try await recoveryStore.releaseLease(nextLease))
        try await recoveryStore.stop()
    } catch {
        try? await recoveryStore.stop()
        throw error
    }
}

private enum TurnBasedRedisTestError: Error { case invalidCommand }

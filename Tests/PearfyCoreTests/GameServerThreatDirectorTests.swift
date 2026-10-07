import Foundation
import PearfyGameServer
import PearfyGameServerThreatDirector
import Testing

private func threatDirectorConfiguration(maximumEvents: Int = 16) throws -> GameThreatDirectorConfiguration {
    try GameThreatDirectorConfiguration(
        maximumPressure: 1_000, alertThreshold: 10, dangerThreshold: 20, huntThreshold: 30,
        hysteresis: 5, decayPerTick: 1, actionCooldownTicks: 3, maximumPlayers: 4,
        maximumEvents: maximumEvents,
        weights: GameThreatWeights(noise: 1, evidence: 10, objective: 15, incapacitatedPlayer: 200),
        actionIDs: [.alert: ["investigate"], .danger: ["stalk", "block-exit"], .hunt: ["attack"]]
    )
}

@Test func threatDirectorScoresSignalsUsesHysteresisAndDeduplicatesEvents() async throws {
    let director = GameThreatDirector(configuration: try threatDirectorConfiguration(), seed: 44)
    let firstID = UUID()
    let first = try await director.evaluate(GameThreatSignal(eventID: firstID, tick: 10, noise: 10))
    #expect(first.pressure == 10)
    #expect(first.level == .alert)
    #expect(first.transitioned)
    #expect(first.recommendedActionID == "investigate")
    #expect(try await director.evaluate(GameThreatSignal(eventID: firstID, tick: 10, noise: 10)) == first)
    do {
        _ = try await director.evaluate(GameThreatSignal(eventID: firstID, tick: 10, noise: 11))
        Issue.record("expected conflicting event ID reuse to fail")
    } catch { #expect(error as? GameThreatDirectorError == .eventIDConflict) }

    let held = try await director.evaluate(GameThreatSignal(tick: 11))
    #expect(held.pressure == 9)
    #expect(held.level == .alert)
    #expect(!held.transitioned)
    #expect(held.recommendedActionID == nil)

    let calm = try await director.evaluate(GameThreatSignal(tick: 16))
    #expect(calm.pressure == 4)
    #expect(calm.level == .calm)
    #expect(calm.transitioned)
}

@Test func threatDirectorProducesDeterministicActionsAndSchedulesAllowlistedPayload() async throws {
    let configuration = try threatDirectorConfiguration()
    let left = GameThreatDirector(configuration: configuration, seed: 900)
    let right = GameThreatDirector(configuration: configuration, seed: 900)
    let signal = GameThreatSignal(tick: 1, evidenceFound: 2, incapacitatedPlayers: 1)
    let lhs = try await left.evaluate(signal)
    let rhs = try await right.evaluate(signal)
    #expect(lhs == rhs)
    #expect(lhs.level == .hunt)
    #expect(lhs.recommendedActionID == "attack")

    let scheduledID = UUID()
    let action = try lhs.scheduledAction(npcID: "warden-1", dueTick: 12, id: scheduledID)
    #expect(action.id == scheduledID)
    #expect(action.npcID == "warden-1")
    #expect(action.dueTick == 12)
    #expect(action.payload.count <= 512)

    let session = try GameCoopSession(objectives: [])
    try await session.join(playerID: UUID())
    try await session.start()
    #expect(try await session.scheduleNPCAction(action))
}

@Test func threatDirectorCheckpointRestoresPressureCooldownAndDedupe() async throws {
    let configuration = try threatDirectorConfiguration()
    let original = GameThreatDirector(configuration: configuration, seed: 55)
    let signal = GameThreatSignal(eventID: UUID(), tick: 5, noise: 35)
    let decision = try await original.evaluate(signal)
    let checkpoint = await original.checkpoint()
    let checkpointData = try JSONEncoder().encode(checkpoint)
    let decodedCheckpoint = try JSONDecoder().decode(GameThreatDirectorCheckpoint.self, from: checkpointData)
    let restored = try GameThreatDirector(configuration: configuration, seed: 55, restoring: decodedCheckpoint)
    #expect(try await restored.evaluate(signal) == decision)
    do {
        _ = try GameThreatDirector(configuration: configuration, seed: 56, restoring: checkpoint)
        Issue.record("expected checkpoint seed mismatch to fail")
    } catch { #expect(error as? GameThreatDirectorError == .invalidCheckpoint) }
    let next = try await restored.evaluate(GameThreatSignal(tick: 6))
    #expect(next.pressure == 34)
    #expect(next.level == .hunt)
    #expect(next.recommendedActionID == nil)
}

@Test func threatDirectorRejectsInvalidAndStaleSignalsWithoutMutation() async throws {
    let director = GameThreatDirector(configuration: try threatDirectorConfiguration(), seed: 1)
    let accepted = try await director.evaluate(GameThreatSignal(tick: 8, noise: 3))
    do {
        _ = try await director.evaluate(GameThreatSignal(tick: 7, noise: 100))
        Issue.record("expected stale tick rejection")
    } catch { #expect(error as? GameThreatDirectorError == .staleTick) }
    do {
        _ = try await director.evaluate(GameThreatSignal(tick: 9, evidenceFound: 33))
        Issue.record("expected an over-capacity signal to be rejected")
    } catch { #expect(error as? GameThreatDirectorError == .invalidSignal) }
    #expect((await director.checkpoint()).pressure == accepted.pressure)
    #expect((await director.checkpoint()).lastTick == 8)
}

@Test func threatDirectorBoundsEventHistoryBeforeMutation() async throws {
    let director = GameThreatDirector(configuration: try threatDirectorConfiguration(maximumEvents: 1), seed: 1)
    _ = try await director.evaluate(GameThreatSignal(tick: 1, noise: 1))
    let checkpoint = await director.checkpoint()
    do {
        _ = try await director.evaluate(GameThreatSignal(tick: 2, noise: 100))
        Issue.record("expected event history to reject growth past its configured bound")
    } catch { #expect(error as? GameThreatDirectorError == .eventHistoryFull) }
    #expect(await director.checkpoint() == checkpoint)
}

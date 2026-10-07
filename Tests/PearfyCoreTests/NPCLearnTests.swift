import Foundation
import PearfyAI
import PearfyCloud
import PearfyGameServer
import PearfyGameServerNPCLearn
import Testing

private struct StaticJevProvider: JevDecisionProvider {
    let answer: String
    let confidence: Double
    func choose(state: String, question: String, options: [JevChoiceOption]) async throws -> JevChoiceDecision {
        JevChoiceDecision(choice: answer, confidence: confidence, probabilities: [answer: confidence], model: "jev-test")
    }
}

private struct JevStubTransport: CloudHTTPTransport {
    let response: CloudHTTPResponse
    func send(_ request: URLRequest) async throws -> CloudHTTPResponse { response }
}

@Test func npcLearnDefaultsToServerSideJevClient() async throws {
    let module = try NPCLearn(apiKey: "test-only")
    #expect(await module.provider is JevDecisionClient)
    #expect(await module.maximumConcurrentRequests == 8)
}

@Test func jevDecisionClientDecodesTypedChoiceWithoutLiveProvider() async throws {
    let body = Data(#"{"model":"jev-test","answers":{"npc_action":{"type":"choice","choice":"wait","confidence":0.88,"probabilities":{"wait":0.88,"patrol":0.12}}}}"#.utf8)
    let client = try JevDecisionClient(
        apiKey: "test-only",
        transport: JevStubTransport(response: CloudHTTPResponse(statusCode: 200, body: body))
    )
    let decision = try await client.choose(
        state: "Guard at gate", question: "Choose an action",
        options: [JevChoiceOption(id: "wait", description: "Wait"), JevChoiceOption(id: "patrol", description: "Patrol")]
    )
    #expect(decision.choice == "wait")
    #expect(decision.confidence == 0.88)
}

@Test func npcLearnUsesAllowlistedJevDecision() async throws {
    let module = try NPCLearn(provider: StaticJevProvider(answer: "patrol", confidence: 0.91))
    let context = NPCDecisionContext(
        npcID: "guard-1", state: "At the north gate; no threat visible.", question: "Choose the next action.",
        candidates: [NPCActionCandidate(id: "patrol", description: "Continue the patrol"),
                     NPCActionCandidate(id: "wait", description: "Wait at the gate")],
        safeFallbackActionID: "wait"
    )
    let decision = try await module.decide(context)
    #expect(decision.actionID == "patrol")
    #expect(!decision.usedFallback)
}

@Test func npcLearnUsesFallbackForLowConfidence() async throws {
    let lowConfidence = try NPCLearn(provider: StaticJevProvider(answer: "patrol", confidence: 0.1))
    let context = NPCDecisionContext(
        npcID: "guard-1", state: "Uncertain situation.", question: "Choose the next action.",
        candidates: [NPCActionCandidate(id: "patrol", description: "Patrol"),
                     NPCActionCandidate(id: "wait", description: "Wait")],
        safeFallbackActionID: "wait"
    )
    let decision = try await lowConfidence.decide(context)
    #expect(decision.actionID == "wait")
    #expect(decision.usedFallback)
}

@Test func npcLearnNormalizesInvalidProviderConfidenceToSafeFallback() async throws {
    let module = try NPCLearn(provider: StaticJevProvider(answer: "patrol", confidence: .nan))
    let context = NPCDecisionContext(
        npcID: "guard-1", state: "Uncertain situation.", question: "Choose the next action.",
        candidates: [NPCActionCandidate(id: "patrol", description: "Patrol"),
                     NPCActionCandidate(id: "wait", description: "Wait")],
        safeFallbackActionID: "wait"
    )
    let action = try await module.planAction(context, dueTick: 7)
    let payload = try JSONDecoder().decode(NPCLearnedNPCAction.self, from: action.payload)
    #expect(payload.actionID == "wait")
    #expect(payload.confidence == 0)
    #expect(payload.usedFallback)
}

@Test func npcLearnBuildsServerAuthoredBoundedCoopAction() async throws {
    let module = try NPCLearn(provider: StaticJevProvider(answer: "investigate", confidence: 0.9))
    let actionID = UUID()
    let action = try await module.planAction(
        NPCDecisionContext(
            npcID: "entity-guard-1", state: "Noise heard in the east hall.", question: "Choose the next NPC action.",
            candidates: [NPCActionCandidate(id: "investigate", description: "Investigate the east hall"),
                         NPCActionCandidate(id: "wait", description: "Wait safely")],
            safeFallbackActionID: "wait"
        ),
        dueTick: 24,
        scheduledActionID: actionID
    )
    let payload = try JSONDecoder().decode(NPCLearnedNPCAction.self, from: action.payload)
    #expect(action.id == actionID)
    #expect(action.npcID == "entity-guard-1")
    #expect(action.dueTick == 24)
    #expect(payload.schemaVersion == 1)
    #expect(payload.actionID == "investigate")
    #expect(action.payload.count <= 2_048)

    let session = try GameCoopSession(objectives: [])
    try await session.join(playerID: UUID())
    try await session.start()
    #expect(try await session.scheduleNPCAction(action))
    let due = try await session.advanceNPCSchedule(to: 24)
    #expect(due.actions == [action])
}

import Foundation
import PearfyAI
import PearfyGameServer

public struct NPCActionCandidate: Sendable, Equatable, Identifiable {
    public let id: String
    public let description: String
    public init(id: String, description: String) {
        self.id = id
        self.description = description
    }
}

public struct NPCDecisionContext: Sendable, Equatable {
    public let npcID: String
    public let state: String
    public let question: String
    public let candidates: [NPCActionCandidate]
    public let safeFallbackActionID: String
    public let minimumConfidence: Double

    public init(npcID: String, state: String, question: String,
                candidates: [NPCActionCandidate], safeFallbackActionID: String,
                minimumConfidence: Double = 0.65) {
        self.npcID = npcID
        self.state = state
        self.question = question
        self.candidates = candidates
        self.safeFallbackActionID = safeFallbackActionID
        self.minimumConfidence = minimumConfidence
    }
}

public struct NPCDecision: Sendable, Equatable {
    public let npcID: String
    public let actionID: String
    public let confidence: Double
    public let model: String?
    public let usedFallback: Bool
}

/// Bounded, versioned payload the application's authoritative NPC action handler decodes.
public struct NPCLearnedNPCAction: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public let actionID: String
    public let confidence: Double
    public let usedFallback: Bool

    public init(schemaVersion: Int = 1, actionID: String, confidence: Double, usedFallback: Bool) {
        self.schemaVersion = schemaVersion
        self.actionID = actionID
        self.confidence = confidence
        self.usedFallback = usedFallback
    }
}

public enum NPCLearnError: Error, Sendable, Equatable {
    case invalidConfiguration
    case overloaded
    case invalidDecision
}

/// Makes bounded, event-driven decisions outside simulation ticks. It returns
/// an allowlisted action identifier; the application remains responsible for
/// validating and scheduling the resulting authoritative NPC action.
public actor NPCLearn {
    public let provider: any JevDecisionProvider
    public let maximumConcurrentRequests: Int
    private var inFlightRequests = 0

    public init(provider: any JevDecisionProvider, maximumConcurrentRequests: Int = 8) throws {
        guard (1...256).contains(maximumConcurrentRequests) else { throw NPCLearnError.invalidConfiguration }
        self.provider = provider
        self.maximumConcurrentRequests = maximumConcurrentRequests
    }

    /// Creates the standard server-side Jev-backed NPC decision module.
    /// Supply the credential from secret-backed server configuration; it is never
    /// included in a decision, scheduled action or checkpoint.
    public init(
        apiKey: String,
        model: String = "jev-latest",
        maximumConcurrentRequests: Int = 8
    ) throws {
        try self.init(
            provider: JevDecisionClient(apiKey: apiKey, model: model),
            maximumConcurrentRequests: maximumConcurrentRequests
        )
    }

    public func decide(_ context: NPCDecisionContext) async throws -> NPCDecision {
        guard !context.npcID.isEmpty, context.npcID.utf8.count <= 128,
              !context.state.isEmpty, context.state.utf8.count <= 16_384,
              !context.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              context.question.utf8.count <= 1_024,
              context.candidates.count >= 2, context.candidates.count <= 32,
              Set(context.candidates.map(\.id)).count == context.candidates.count,
              context.candidates.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 && !$0.description.isEmpty && $0.description.utf8.count <= 512 }),
              context.candidates.contains(where: { $0.id == context.safeFallbackActionID }),
              context.minimumConfidence.isFinite, (0...1).contains(context.minimumConfidence) else {
            throw NPCLearnError.invalidConfiguration
        }
        guard inFlightRequests < maximumConcurrentRequests else { throw NPCLearnError.overloaded }
        inFlightRequests += 1
        defer { inFlightRequests -= 1 }
        do {
            let decision = try await provider.choose(
                state: context.state,
                question: context.question,
                options: context.candidates.map { JevChoiceOption(id: $0.id, description: $0.description) }
            )
            guard decision.confidence.isFinite, (0...1).contains(decision.confidence) else {
                return NPCDecision(npcID: context.npcID, actionID: context.safeFallbackActionID,
                                   confidence: 0, model: nil, usedFallback: true)
            }
            guard let candidate = context.candidates.first(where: { $0.id == decision.choice }),
                  decision.confidence >= context.minimumConfidence else {
                return NPCDecision(npcID: context.npcID, actionID: context.safeFallbackActionID,
                                   confidence: decision.confidence, model: decision.model, usedFallback: true)
            }
            return NPCDecision(npcID: context.npcID, actionID: candidate.id,
                               confidence: decision.confidence, model: decision.model, usedFallback: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return NPCDecision(npcID: context.npcID, actionID: context.safeFallbackActionID,
                               confidence: 0, model: nil, usedFallback: true)
        }
    }

    /// Converts a model recommendation to the core scheduler's server-authored action.
    /// The app must still commit this action (durably when required) and execute only
    /// known action identifiers through its authoritative tick handler.
    public func planAction(
        _ context: NPCDecisionContext,
        dueTick: UInt64,
        scheduledActionID: UUID = UUID()
    ) async throws -> GameCoopScheduledNPCAction {
        let decision = try await decide(context)
        let payload = NPCLearnedNPCAction(
            actionID: decision.actionID,
            confidence: decision.confidence,
            usedFallback: decision.usedFallback
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard data.count <= 2_048 else { throw NPCLearnError.invalidDecision }
        return GameCoopScheduledNPCAction(
            id: scheduledActionID,
            npcID: decision.npcID,
            dueTick: dueTick,
            payload: data
        )
    }
}

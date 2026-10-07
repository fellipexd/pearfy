import Foundation
import PearfyGameServer

public enum GameThreatLevel: Int, Sendable, Codable, CaseIterable, Comparable {
    case calm = 0
    case alert = 1
    case danger = 2
    case hunt = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct GameThreatWeights: Sendable, Equatable, Codable {
    public let noise: UInt16
    public let evidence: UInt16
    public let objective: UInt16
    public let incapacitatedPlayer: UInt16

    public init(noise: UInt16 = 2, evidence: UInt16 = 20, objective: UInt16 = 30,
                incapacitatedPlayer: UInt16 = 80) {
        self.noise = noise
        self.evidence = evidence
        self.objective = objective
        self.incapacitatedPlayer = incapacitatedPlayer
    }
}

public struct GameThreatDirectorConfiguration: Sendable, Equatable, Codable {
    public let maximumPressure: UInt16
    public let alertThreshold: UInt16
    public let dangerThreshold: UInt16
    public let huntThreshold: UInt16
    public let hysteresis: UInt16
    public let decayPerTick: UInt16
    public let actionCooldownTicks: UInt64
    public let maximumPlayers: UInt8
    public let maximumEvents: Int
    public let weights: GameThreatWeights
    public let actionIDs: [GameThreatLevel: [String]]

    public init(maximumPressure: UInt16 = 1_000, alertThreshold: UInt16 = 250,
                dangerThreshold: UInt16 = 600, huntThreshold: UInt16 = 850,
                hysteresis: UInt16 = 40, decayPerTick: UInt16 = 1,
                actionCooldownTicks: UInt64 = 20, maximumPlayers: UInt8 = 8,
                maximumEvents: Int = 10_000, weights: GameThreatWeights = .init(),
                actionIDs: [GameThreatLevel: [String]]) throws {
        let identifiers = actionIDs.values.flatMap { $0 }
        guard maximumPressure > 0, alertThreshold > 0,
              alertThreshold < dangerThreshold, dangerThreshold < huntThreshold,
              huntThreshold <= maximumPressure, hysteresis < alertThreshold,
              decayPerTick > 0, actionCooldownTicks > 0,
              (1...64).contains(maximumPlayers), (1...10_000).contains(maximumEvents),
              GameThreatLevel.allCases.filter({ $0 != .calm }).allSatisfy({
                  guard let ids = actionIDs[$0], (1...16).contains(ids.count) else { return false }
                  return ids.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 }
              }), identifiers.count <= 64, Set(identifiers).count == identifiers.count else {
            throw GameThreatDirectorError.invalidConfiguration
        }
        self.maximumPressure = maximumPressure
        self.alertThreshold = alertThreshold
        self.dangerThreshold = dangerThreshold
        self.huntThreshold = huntThreshold
        self.hysteresis = hysteresis
        self.decayPerTick = decayPerTick
        self.actionCooldownTicks = actionCooldownTicks
        self.maximumPlayers = maximumPlayers
        self.maximumEvents = maximumEvents
        self.weights = weights
        self.actionIDs = actionIDs
    }
}

public struct GameThreatSignal: Sendable, Equatable, Codable {
    public let eventID: UUID
    public let tick: UInt64
    /// Noise is normalized to 0...100 by the game application.
    public let noise: UInt8
    public let evidenceFound: UInt8
    public let objectivesCompleted: UInt8
    public let incapacitatedPlayers: UInt8

    public init(eventID: UUID = UUID(), tick: UInt64, noise: UInt8 = 0,
                evidenceFound: UInt8 = 0, objectivesCompleted: UInt8 = 0,
                incapacitatedPlayers: UInt8 = 0) {
        self.eventID = eventID
        self.tick = tick
        self.noise = noise
        self.evidenceFound = evidenceFound
        self.objectivesCompleted = objectivesCompleted
        self.incapacitatedPlayers = incapacitatedPlayers
    }
}

public struct GameThreatDecision: Sendable, Equatable, Codable {
    public let eventID: UUID
    public let tick: UInt64
    public let pressure: UInt16
    public let level: GameThreatLevel
    public let transitioned: Bool
    public let recommendedActionID: String?
    public let decisionSequence: UInt64
}

public struct GameThreatProcessedEvent: Sendable, Equatable, Codable {
    public let signal: GameThreatSignal
    public let decision: GameThreatDecision

    fileprivate init(signal: GameThreatSignal, decision: GameThreatDecision) {
        self.signal = signal
        self.decision = decision
    }
}

public struct GameThreatDirectorCheckpoint: Sendable, Equatable, Codable {
    public let schemaVersion: UInt16
    public let seed: UInt64
    public let configuration: GameThreatDirectorConfiguration
    public let pressure: UInt16
    public let level: GameThreatLevel
    public let lastTick: UInt64?
    public let lastActionTick: UInt64?
    public let decisionSequence: UInt64
    public let processedEvents: [UUID: GameThreatProcessedEvent]

    fileprivate init(seed: UInt64, configuration: GameThreatDirectorConfiguration,
                     pressure: UInt16, level: GameThreatLevel, lastTick: UInt64?,
                     lastActionTick: UInt64?, decisionSequence: UInt64,
                     processedEvents: [UUID: GameThreatProcessedEvent]) {
        schemaVersion = 1
        self.seed = seed
        self.configuration = configuration
        self.pressure = pressure
        self.level = level
        self.lastTick = lastTick
        self.lastActionTick = lastActionTick
        self.decisionSequence = decisionSequence
        self.processedEvents = processedEvents
    }
}

public enum GameThreatDirectorError: Error, Sendable, Equatable {
    case invalidConfiguration
    case invalidSignal
    case staleTick
    case eventIDConflict
    case eventHistoryFull
    case invalidCheckpoint
}

/// Deterministic, bounded threat scoring outside latency-critical simulation ticks. The application
/// validates the recommended action and schedules it through its authoritative path.
public actor GameThreatDirector {
    public let configuration: GameThreatDirectorConfiguration
    private let seed: UInt64
    private var pressure: UInt16 = 0
    private var level: GameThreatLevel = .calm
    private var lastTick: UInt64?
    private var lastActionTick: UInt64?
    private var decisionSequence: UInt64 = 0
    private var processedEvents: [UUID: GameThreatProcessedEvent] = [:]

    public init(configuration: GameThreatDirectorConfiguration, seed: UInt64) {
        self.configuration = configuration
        self.seed = seed
    }

    public init(configuration: GameThreatDirectorConfiguration, seed: UInt64,
                restoring checkpoint: GameThreatDirectorCheckpoint) throws {
        guard checkpoint.schemaVersion == 1,
              checkpoint.seed == seed, checkpoint.configuration == configuration,
              checkpoint.pressure <= configuration.maximumPressure,
              Self.isPlausible(checkpoint.level, pressure: checkpoint.pressure, configuration: configuration),
              checkpoint.decisionSequence < .max,
              checkpoint.lastTick.map({ last in checkpoint.processedEvents.values.allSatisfy { $0.decision.tick <= last } }) ?? checkpoint.processedEvents.isEmpty,
              checkpoint.lastActionTick.map({ actionTick in checkpoint.lastTick.map { actionTick <= $0 } ?? false }) ?? true,
              checkpoint.processedEvents.count <= configuration.maximumEvents,
              checkpoint.processedEvents.allSatisfy({ key, event in
                  key == event.signal.eventID && event.decision.eventID == key
                    && event.signal.tick == event.decision.tick
                    && event.signal.noise <= 100 && event.signal.evidenceFound <= 32
                    && event.signal.objectivesCompleted <= 32
                    && event.signal.incapacitatedPlayers <= configuration.maximumPlayers
                    && event.decision.pressure <= configuration.maximumPressure
                    && (event.decision.recommendedActionID.map { configuration.actionIDs[event.decision.level, default: []].contains($0) } ?? true)
                    && event.decision.decisionSequence <= checkpoint.decisionSequence
              }) else {
            throw GameThreatDirectorError.invalidCheckpoint
        }
        self.configuration = configuration
        self.seed = seed
        pressure = checkpoint.pressure
        level = checkpoint.level
        lastTick = checkpoint.lastTick
        lastActionTick = checkpoint.lastActionTick
        decisionSequence = checkpoint.decisionSequence
        processedEvents = checkpoint.processedEvents
    }

    public func evaluate(_ signal: GameThreatSignal) throws -> GameThreatDecision {
        if let previous = processedEvents[signal.eventID] {
            guard previous.signal == signal else { throw GameThreatDirectorError.eventIDConflict }
            return previous.decision
        }
        guard processedEvents.count < configuration.maximumEvents else {
            throw GameThreatDirectorError.eventHistoryFull
        }
        guard signal.noise <= 100,
              signal.incapacitatedPlayers <= configuration.maximumPlayers else {
            throw GameThreatDirectorError.invalidSignal
        }
        if let lastTick, signal.tick < lastTick { throw GameThreatDirectorError.staleTick }

        var nextPressure = UInt64(pressure)
        if let lastTick {
            let elapsed = signal.tick - lastTick
            let (rawDecay, overflow) = elapsed.multipliedReportingOverflow(by: UInt64(configuration.decayPerTick))
            let decay = overflow ? UInt64(configuration.maximumPressure)
                : min(UInt64(configuration.maximumPressure), rawDecay)
            nextPressure = nextPressure > decay ? nextPressure - decay : 0
        }
        guard signal.evidenceFound <= 32, signal.objectivesCompleted <= 32 else {
            throw GameThreatDirectorError.invalidSignal
        }
        let weights = configuration.weights
        nextPressure = min(UInt64(configuration.maximumPressure), nextPressure
            + UInt64(signal.noise) * UInt64(weights.noise)
            + UInt64(signal.evidenceFound) * UInt64(weights.evidence)
            + UInt64(signal.objectivesCompleted) * UInt64(weights.objective)
            + UInt64(signal.incapacitatedPlayers) * UInt64(weights.incapacitatedPlayer))
        pressure = UInt16(nextPressure)
        let previousLevel = level
        level = resolvedLevel(for: pressure, from: level)
        let transitioned = previousLevel != level
        var actionID: String?
        if level != .calm,
           transitioned || lastActionTick.map({ signal.tick >= $0 && signal.tick - $0 >= configuration.actionCooldownTicks }) ?? true {
            let candidates = configuration.actionIDs[level, default: []]
            if !candidates.isEmpty {
                decisionSequence &+= 1
                let mixed = seed &+ (decisionSequence &* 0x9E3779B97F4A7C15)
                let index = Int(mixed % UInt64(candidates.count))
                actionID = candidates[index]
                lastActionTick = signal.tick
            }
        }
        lastTick = signal.tick
        let decision = GameThreatDecision(eventID: signal.eventID, tick: signal.tick,
            pressure: pressure, level: level, transitioned: transitioned,
            recommendedActionID: actionID, decisionSequence: decisionSequence)
        processedEvents[signal.eventID] = GameThreatProcessedEvent(signal: signal, decision: decision)
        return decision
    }

    public func checkpoint() -> GameThreatDirectorCheckpoint {
        GameThreatDirectorCheckpoint(seed: seed, configuration: configuration,
            pressure: pressure, level: level, lastTick: lastTick,
            lastActionTick: lastActionTick, decisionSequence: decisionSequence,
            processedEvents: processedEvents)
    }

    private func resolvedLevel(for pressure: UInt16, from current: GameThreatLevel) -> GameThreatLevel {
        let candidate: GameThreatLevel = pressure >= configuration.huntThreshold ? .hunt
            : pressure >= configuration.dangerThreshold ? .danger
            : pressure >= configuration.alertThreshold ? .alert : .calm
        if candidate >= current { return candidate }
        var resolved = current
        while candidate < resolved {
            let boundary = threshold(for: resolved)
            let exit = boundary > configuration.hysteresis ? boundary - configuration.hysteresis : 0
            if pressure < exit { resolved = GameThreatLevel(rawValue: resolved.rawValue - 1) ?? .calm }
            else { return resolved }
        }
        return resolved
    }

    private func threshold(for level: GameThreatLevel) -> UInt16 {
        switch level {
        case .calm: 0
        case .alert: configuration.alertThreshold
        case .danger: configuration.dangerThreshold
        case .hunt: configuration.huntThreshold
        }
    }

    private static func isPlausible(_ level: GameThreatLevel, pressure: UInt16,
                                    configuration: GameThreatDirectorConfiguration) -> Bool {
        switch level {
        case .calm:
            pressure < configuration.alertThreshold
        case .alert:
            pressure >= configuration.alertThreshold - configuration.hysteresis
                && pressure < configuration.dangerThreshold
        case .danger:
            pressure >= configuration.dangerThreshold - configuration.hysteresis
                && pressure < configuration.huntThreshold
        case .hunt:
            pressure >= configuration.huntThreshold - configuration.hysteresis
        }
    }
}

public extension GameThreatDecision {
    /// Converts only the director's allowlisted recommendation into an opaque action.
    /// The caller supplies the trusted NPC ID and still validates the world state.
    func scheduledAction(npcID: String, dueTick: UInt64, id: UUID = UUID()) throws -> GameCoopScheduledNPCAction {
        guard let recommendedActionID, !npcID.isEmpty, npcID.utf8.count <= 128 else {
            throw GameThreatDirectorError.invalidSignal
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(ActionPayload(schemaVersion: 1, actionID: recommendedActionID,
                                                       pressure: pressure, level: level))
        guard payload.count <= 512 else { throw GameThreatDirectorError.invalidSignal }
        return GameCoopScheduledNPCAction(id: id, npcID: npcID, dueTick: dueTick, payload: payload)
    }

    private struct ActionPayload: Codable {
        let schemaVersion: Int
        let actionID: String
        let pressure: UInt16
        let level: GameThreatLevel
    }
}

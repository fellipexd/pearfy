import Foundation
import PearfyGameServer
import PearfyGameServerRedisRecovery
import PearfyGameServerTurnBased

public enum RedisGameTurnBasedStoreError: Error, Sendable, Equatable {
    case invalidConfiguration
    case wrongSession
    case invalidStoredHistory
    case historyCapacityReached
    case checkpointTooLarge
    case commitInProgress
}

public struct RedisGameTurnBasedConfiguration: Sendable, Equatable {
    public let maximumEvents: Int
    public let maximumStateBytes: Int
    public let maximumHistoryBytes: Int
    public let maximumCommandBytes: Int
    public let maximumEventBytes: Int
    public let maximumCheckpointBytes: Int

    public init(
        maximumEvents: Int = 100_000,
        maximumStateBytes: Int = 1_048_576,
        maximumHistoryBytes: Int = 8_388_608,
        maximumCommandBytes: Int = 65_536,
        maximumEventBytes: Int = 1_500_000,
        maximumCheckpointBytes: Int = 16_777_216
    ) throws {
        guard (1...1_000_000).contains(maximumEvents),
              (1...16_777_216).contains(maximumStateBytes),
              (1...1_073_741_824).contains(maximumHistoryBytes),
              (1...1_048_576).contains(maximumCommandBytes),
              (256...33_554_432).contains(maximumEventBytes),
              (1_024...268_435_456).contains(maximumCheckpointBytes) else {
            throw RedisGameTurnBasedStoreError.invalidConfiguration
        }
        self.maximumEvents = maximumEvents
        self.maximumStateBytes = maximumStateBytes
        self.maximumHistoryBytes = maximumHistoryBytes
        self.maximumCommandBytes = maximumCommandBytes
        self.maximumEventBytes = maximumEventBytes
        self.maximumCheckpointBytes = maximumCheckpointBytes
    }
}

/// Redis Streams implementation of the bounded turn-based compare-and-append store.
/// The caller must acquire a fencing lease before opening it and renew/release that
/// lease through `RedisGameStateRecoveryStore`. A checkpoint embeds the complete
/// finite event history before Redis trims the covered stream prefix.
public actor RedisGameTurnBasedCommandStore: GameTurnBasedCommandStore {
    private let sessionID: UUID
    private let lease: GameStateSessionLease
    private let recoveryStore: any GameStateRecoveryStore
    private let configuration: RedisGameTurnBasedConfiguration
    private var checkpoint: GameStateCheckpoint
    private var historyBytes: Int
    private var appendInProgress = false
    private var appendOutcomeUncertain = false

    private init(
        sessionID: UUID,
        lease: GameStateSessionLease,
        recoveryStore: any GameStateRecoveryStore,
        configuration: RedisGameTurnBasedConfiguration,
        checkpoint: GameStateCheckpoint,
        historyBytes: Int
    ) {
        self.sessionID = sessionID
        self.lease = lease
        self.recoveryStore = recoveryStore
        self.configuration = configuration
        self.checkpoint = checkpoint
        self.historyBytes = historyBytes
    }

    /// Opens under an already acquired lease. A new Redis session is initialized
    /// with the supplied state; an existing session restores its full checkpoint
    /// plus the journal suffix and rejects any lease or sequence mismatch.
    public static func open(
        sessionID: UUID,
        lease: GameStateSessionLease,
        recoveryStore: any GameStateRecoveryStore,
        initialState: Data,
        configuration requestedConfiguration: RedisGameTurnBasedConfiguration? = nil
    ) async throws -> RedisGameTurnBasedCommandStore {
        let configuration = try requestedConfiguration ?? RedisGameTurnBasedConfiguration()
        guard lease.sessionID == sessionID, lease.epoch > 0,
              initialState.count <= configuration.maximumStateBytes else {
            throw RedisGameTurnBasedStoreError.invalidConfiguration
        }

        guard let recovered = try await recoveryStore.load(sessionID: sessionID) else {
            let initial = GameStateCheckpoint(revision: 0, state: initialState, events: [])
            try Self.validateCheckpoint(initial, configuration: configuration)
            try await recoveryStore.save(sessionID: sessionID, epoch: lease.epoch, checkpoint: initial)
            return RedisGameTurnBasedCommandStore(
                sessionID: sessionID, lease: lease, recoveryStore: recoveryStore,
                configuration: configuration, checkpoint: initial, historyBytes: 0
            )
        }
        guard recovered.epoch == lease.epoch else { throw RedisGameStateRecoveryError.staleEpoch }
        let restored = try Self.combine(recovered, configuration: configuration)
        return RedisGameTurnBasedCommandStore(
            sessionID: sessionID, lease: lease, recoveryStore: recoveryStore,
            configuration: configuration, checkpoint: restored.checkpoint, historyBytes: restored.historyBytes
        )
    }

    public func load(sessionID: UUID) async throws -> GameStateCheckpoint? {
        guard sessionID == self.sessionID else { throw RedisGameTurnBasedStoreError.wrongSession }
        guard !appendInProgress else { throw RedisGameTurnBasedStoreError.commitInProgress }
        return try await refresh()
    }

    public func append(
        sessionID: UUID,
        expectedRevision: UInt64,
        event: GameStateEvent
    ) async throws -> GameTurnBasedStoreResult {
        guard sessionID == self.sessionID else { throw RedisGameTurnBasedStoreError.wrongSession }
        guard !appendInProgress else { throw RedisGameTurnBasedStoreError.commitInProgress }
        appendInProgress = true
        defer { appendInProgress = false }

        if appendOutcomeUncertain {
            _ = try await refresh()
            appendOutcomeUncertain = false
        }

        if event.sequence <= checkpoint.revision {
            if let prior = checkpoint.events.first(where: { $0.commandID == event.commandID }) {
                guard prior == event else { throw GameServerError.commandIDConflict }
                guard prior.sequence == checkpoint.revision else {
                    throw GameServerError.revisionConflict(current: checkpoint.revision)
                }
                return .duplicate(prior)
            }
            throw GameServerError.revisionConflict(current: checkpoint.revision)
        }

        guard checkpoint.revision == expectedRevision else {
            throw GameServerError.revisionConflict(current: checkpoint.revision)
        }
        guard expectedRevision < UInt64(configuration.maximumEvents),
              event.sequence == expectedRevision + 1,
              event.payload.count <= configuration.maximumCommandBytes,
              event.state.count <= configuration.maximumStateBytes else {
            throw RedisGameTurnBasedStoreError.invalidConfiguration
        }
        let (eventBytes, overflow) = event.payload.count.addingReportingOverflow(event.state.count)
        guard !overflow, eventBytes <= configuration.maximumHistoryBytes,
              historyBytes <= configuration.maximumHistoryBytes - eventBytes else {
            throw RedisGameTurnBasedStoreError.historyCapacityReached
        }
        let encodedEvent = try JSONEncoder().encode(event)
        guard encodedEvent.count <= configuration.maximumEventBytes else {
            throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: configuration.maximumEventBytes)
        }

        do {
            try await recoveryStore.append(sessionID: sessionID, epoch: lease.epoch, event: event)
        } catch {
            appendOutcomeUncertain = true
            if let recoveryError = error as? RedisGameStateRecoveryError,
               recoveryError == .sequenceConflict {
                _ = try await refresh()
                throw GameServerError.revisionConflict(current: checkpoint.revision)
            }
            throw error
        }
        checkpoint = GameStateCheckpoint(
            revision: event.sequence, state: event.state, events: checkpoint.events + [event]
        )
        historyBytes += eventBytes
        return .appended(event)
    }

    /// Persists a full bounded checkpoint. The Redis adapter trims only the journal
    /// prefix covered by this revision, while the event history remains recoverable
    /// from the checkpoint. Call on maintenance/shutdown tasks, never in a tick.
    public func saveCheckpoint() async throws {
        guard !appendInProgress else { throw RedisGameTurnBasedStoreError.commitInProgress }
        try Self.validateCheckpoint(checkpoint, configuration: configuration)
        try await recoveryStore.save(sessionID: sessionID, epoch: lease.epoch, checkpoint: checkpoint)
    }

    public var currentRevision: UInt64 { checkpoint.revision }

    /// The fencing token this adapter uses for all Redis mutations. The owner must
    /// renew it through the recovery store for the entire lifetime of this adapter.
    public var sessionLease: GameStateSessionLease { lease }

    private func refresh() async throws -> GameStateCheckpoint? {
        guard let recovered = try await recoveryStore.load(sessionID: sessionID) else {
            throw RedisGameTurnBasedStoreError.invalidStoredHistory
        }
        guard recovered.epoch == lease.epoch else { throw RedisGameStateRecoveryError.staleEpoch }
        let restored = try Self.combine(recovered, configuration: configuration)
        checkpoint = restored.checkpoint
        historyBytes = restored.historyBytes
        return checkpoint
    }

    private static func combine(
        _ recovery: (epoch: UInt64, checkpoint: GameStateCheckpoint, events: [GameStateEvent], latestSequence: UInt64),
        configuration: RedisGameTurnBasedConfiguration
    ) throws -> (checkpoint: GameStateCheckpoint, historyBytes: Int) {
        var events = recovery.checkpoint.events
        guard recovery.checkpoint.revision == UInt64(events.count),
              events.count <= configuration.maximumEvents,
              recovery.checkpoint.state.count <= configuration.maximumStateBytes,
              (events.last?.state ?? recovery.checkpoint.state) == recovery.checkpoint.state,
              recovery.events.allSatisfy({ $0.sequence > recovery.checkpoint.revision }) else {
            throw RedisGameTurnBasedStoreError.invalidStoredHistory
        }
        var state = recovery.checkpoint.state
        var revision = recovery.checkpoint.revision
        var totalBytes = 0
        var commandIDs = Set<UUID>()
        for event in events {
            let (cost, overflow) = event.payload.count.addingReportingOverflow(event.state.count)
            guard !overflow, event.payload.count <= configuration.maximumCommandBytes,
                  event.state.count <= configuration.maximumStateBytes,
                  cost <= configuration.maximumHistoryBytes,
                  totalBytes <= configuration.maximumHistoryBytes - cost,
                  commandIDs.insert(event.commandID).inserted else {
                throw RedisGameTurnBasedStoreError.invalidStoredHistory
            }
            totalBytes += cost
        }
        for event in recovery.events where event.sequence > recovery.checkpoint.revision {
            guard revision < UInt64(configuration.maximumEvents), event.sequence == revision + 1,
                  event.payload.count <= configuration.maximumCommandBytes,
                  event.state.count <= configuration.maximumStateBytes,
                  commandIDs.insert(event.commandID).inserted else {
                throw RedisGameTurnBasedStoreError.invalidStoredHistory
            }
            let (cost, overflow) = event.payload.count.addingReportingOverflow(event.state.count)
            guard !overflow, cost <= configuration.maximumHistoryBytes,
                  totalBytes <= configuration.maximumHistoryBytes - cost else {
                throw RedisGameTurnBasedStoreError.invalidStoredHistory
            }
            totalBytes += cost
            events.append(event)
            revision = event.sequence
            state = event.state
        }
        guard revision == recovery.latestSequence,
              (events.last?.state ?? recovery.checkpoint.state) == state else {
            throw RedisGameTurnBasedStoreError.invalidStoredHistory
        }
        let checkpoint = GameStateCheckpoint(revision: revision, state: state, events: events)
        try validateCheckpoint(checkpoint, configuration: configuration)
        return (checkpoint, totalBytes)
    }

    private static func validateCheckpoint(
        _ checkpoint: GameStateCheckpoint,
        configuration: RedisGameTurnBasedConfiguration
    ) throws {
        let encodedBytes = try JSONEncoder().encode(checkpoint).count
        guard checkpoint.revision == UInt64(checkpoint.events.count),
              checkpoint.events.count <= configuration.maximumEvents,
              checkpoint.state.count <= configuration.maximumStateBytes,
              encodedBytes <= configuration.maximumCheckpointBytes,
              checkpoint.events.last?.state ?? checkpoint.state == checkpoint.state else {
            throw RedisGameTurnBasedStoreError.checkpointTooLarge
        }
    }
}

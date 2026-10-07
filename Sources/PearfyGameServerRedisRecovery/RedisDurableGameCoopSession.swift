import Foundation
import PearfyGameServer

/// Reducible, discrete mutations for `GameCoopSession`. Each command is journaled
/// before its resulting private checkpoint becomes the committed session state.
/// Do not use this adapter for per-frame inputs or NPC tick drains.
public enum RedisDurableGameCoopCommand: Sendable, Codable, Equatable {
    case join(playerID: UUID)
    case start
    case disconnect(playerID: UUID, gracePeriodMilliseconds: Int64, now: Date)
    case reconnect(playerID: UUID, now: Date)
    case abandon(playerID: UUID)
    case completeObjective(objectiveID: String, playerID: UUID, publicState: Data, privatePlayerState: Data?)
    case recordObjectiveProgress(objectiveID: String, delta: UInt64, playerID: UUID, publicState: Data, privatePlayerState: Data?)
    case deterministicDecision
    case scheduleNPCAction(GameCoopScheduledNPCAction)
    case stageNPCActions(tick: UInt64, maximumActions: Int?)
    case acknowledgeNPCActions([UUID])
    case expireDisconnectedMembers(now: Date)
    case finish(extracted: Bool)
    case close
}

private struct EncodedDurableCoopCommand: Codable {
    let schemaVersion: UInt16
    let commandID: UUID
    let command: RedisDurableGameCoopCommand
}

/// Redis write-ahead boundary for discrete co-op mission transitions. State remains
/// inaccessible through this adapter until the command append succeeds. Call from an
/// async command/control task; the Redis append must never run in the simulation tick.
public actor RedisDurableGameCoopSession {
    private let durable: RedisDurableGameCommandSession
    public let sessionID: UUID

    private init(sessionID: UUID, durable: RedisDurableGameCommandSession) {
        self.sessionID = sessionID
        self.durable = durable
    }

    /// Opens a new or existing co-op session using a validated initial domain session.
    /// On recovery the Redis checkpoint and suffix take precedence over `initialSession`.
    public static func open(
        initialSession: GameCoopSession,
        lease: GameStateSessionLease,
        store: any GameStateRecoveryStore,
        configuration: RedisDurableGameCommandConfiguration = .standard
    ) async throws -> RedisDurableGameCoopSession {
        let initialSessionID = await initialSession.sessionID
        guard initialSessionID == lease.sessionID else {
            throw RedisGameStateRecoveryError.invalidConfiguration
        }
        let initialState = try await initialSession.recoveryCheckpointData(
            maximumBytes: configuration.maximumStateBytes
        )
        return try await open(
            sessionID: initialSessionID,
            lease: lease,
            store: store,
            initialState: initialState,
            configuration: configuration
        )
    }

    /// Opens a previously initialized session after acquiring its current fencing lease.
    public static func open(
        sessionID: UUID,
        lease: GameStateSessionLease,
        store: any GameStateRecoveryStore,
        configuration: RedisDurableGameCommandConfiguration = .standard
    ) async throws -> RedisDurableGameCoopSession {
        try await open(
            sessionID: sessionID,
            lease: lease,
            store: store,
            initialState: nil,
            configuration: configuration
        )
    }

    private static func open(
        sessionID: UUID,
        lease: GameStateSessionLease,
        store: any GameStateRecoveryStore,
        initialState: Data?,
        configuration: RedisDurableGameCommandConfiguration
    ) async throws -> RedisDurableGameCoopSession {
        let durable = try await RedisDurableGameCommandSession.openAsync(
            sessionID: sessionID,
            lease: lease,
            store: store,
            initialState: initialState,
            configuration: configuration,
            reducer: { state, playerID, data in
                let decoded = try Self.decode(data, maximumBytes: configuration.maximumCommandBytes)
                let game = try GameCoopSession(
                    restoringCheckpoint: state,
                    maximumCheckpointBytes: configuration.maximumStateBytes
                )
                let recoveredSessionID = await game.sessionID
                guard recoveredSessionID == sessionID else { throw GameServerError.invalidCheckpoint }
                try await Self.apply(decoded.command, commandID: decoded.commandID, playerID: playerID, to: game)
                return try await game.recoveryCheckpointData(maximumBytes: configuration.maximumStateBytes)
            }
        )
        return RedisDurableGameCoopSession(sessionID: sessionID, durable: durable)
    }

    /// Commits one bounded, idempotent domain command and returns its committed journal
    /// sequence plus canonical private checkpoint. Filter snapshots before client delivery.
    public func commit(
        commandID: UUID,
        playerID: UUID,
        command: RedisDurableGameCoopCommand,
        expectedRevision: UInt64? = nil
    ) async throws -> RedisDurableGameCommandReceipt {
        let data = try Self.encode(command, commandID: commandID, maximumBytes: 1_048_576)
        return try await durable.commit(
            commandID: commandID,
            playerID: playerID,
            command: data,
            expectedRevision: expectedRevision
        )
    }

    /// Appends a deterministic RNG decision before returning its value. The journal
    /// sequence is the deterministic counter, so retrying the command ID returns the
    /// same value even after later commands or a recovery checkpoint.
    public func deterministicDecision(
        commandID: UUID,
        playerID: UUID,
        expectedRevision: UInt64? = nil
    ) async throws -> (receipt: RedisDurableGameCommandReceipt, value: UInt64) {
        let receipt = try await commit(
            commandID: commandID,
            playerID: playerID,
            command: .deterministicDecision,
            expectedRevision: expectedRevision
        )
        let game = try GameCoopSession(restoringCheckpoint: receipt.state)
        return (receipt, try await game.deterministicValue(atJournalSequence: receipt.sequence))
    }

    /// Returns the current domain snapshot after applying the co-op visibility checks.
    public func snapshot(for playerID: UUID) async throws -> GameCoopSnapshot {
        let committed = await durable.snapshot()
        let game = try GameCoopSession(restoringCheckpoint: committed.state)
        return try await game.snapshot(for: playerID)
    }

    public func checkpoint() async throws { try await durable.checkpoint() }

    /// Durably stages due actions before returning them for server-side dispatch.
    /// If the append response is ambiguous, retry with the same command ID; pending
    /// actions remain in the checkpoint and are returned again until acknowledged.
    public func stageNPCActions(
        commandID: UUID,
        playerID: UUID,
        tick: UInt64,
        maximumActions: Int? = nil,
        expectedRevision: UInt64? = nil
    ) async throws -> (receipt: RedisDurableGameCommandReceipt, batch: GameCoopNPCActionBatch) {
        let receipt = try await commit(
            commandID: commandID,
            playerID: playerID,
            command: .stageNPCActions(tick: tick, maximumActions: maximumActions),
            expectedRevision: expectedRevision
        )
        let game = try GameCoopSession(restoringCheckpoint: receipt.state)
        return (receipt, try await game.pendingNPCActionBatch(maximumActions: maximumActions))
    }

    /// Acknowledges an already dispatched batch through another write-ahead command.
    /// On recovery, any actions not in a committed acknowledgment are delivered again.
    public func acknowledgeNPCActions(
        commandID: UUID,
        playerID: UUID,
        actionIDs: [UUID],
        expectedRevision: UInt64? = nil
    ) async throws -> RedisDurableGameCommandReceipt {
        try await commit(
            commandID: commandID,
            playerID: playerID,
            command: .acknowledgeNPCActions(actionIDs),
            expectedRevision: expectedRevision
        )
    }

    /// Returns pending outbox actions after startup recovery so the application can
    /// redeliver actions left unacknowledged by the previous process.
    public func pendingNPCActionBatch(maximumActions: Int? = nil) async throws -> GameCoopNPCActionBatch {
        let committed = await durable.snapshot()
        let game = try GameCoopSession(restoringCheckpoint: committed.state)
        return try await game.pendingNPCActionBatch(maximumActions: maximumActions)
    }

    public func journalSnapshot() async -> (revision: UInt64, state: Data) {
        await durable.snapshot()
    }

    private static func apply(
        _ command: RedisDurableGameCoopCommand,
        commandID: UUID,
        playerID: UUID,
        to game: GameCoopSession
    ) async throws {
        switch command {
        case .join(let memberID):
            guard memberID == playerID else { throw GameServerError.roomNotFoundOrUnauthorized }
            try await game.join(playerID: memberID)
        case .start:
            try await game.start()
        case .disconnect(let memberID, let grace, let now):
            guard memberID == playerID else { throw GameServerError.roomNotFoundOrUnauthorized }
            _ = try await game.disconnect(playerID: memberID, gracePeriodMilliseconds: grace, now: now)
        case .reconnect(let memberID, let now):
            guard memberID == playerID else { throw GameServerError.roomNotFoundOrUnauthorized }
            try await game.reconnect(playerID: memberID, now: now)
        case .abandon(let memberID):
            guard memberID == playerID else { throw GameServerError.roomNotFoundOrUnauthorized }
            try await game.abandon(playerID: memberID)
        case .completeObjective(let objectiveID, let memberID, let publicState, let privateState):
            guard memberID == playerID else { throw GameServerError.roomNotFoundOrUnauthorized }
            _ = try await game.completeObjective(
                objectiveID, commandID: commandID, by: memberID,
                publicState: publicState, privatePlayerState: privateState
            )
        case .recordObjectiveProgress(let objectiveID, let delta, let memberID, let publicState, let privateState):
            guard memberID == playerID else { throw GameServerError.roomNotFoundOrUnauthorized }
            _ = try await game.recordObjectiveProgress(
                objectiveID, by: delta, commandID: commandID, playerID: memberID,
                publicState: publicState, privatePlayerState: privateState
            )
        case .deterministicDecision:
            try await game.validateDurableDeterministicDecision(by: playerID)
        case .scheduleNPCAction(let action):
            _ = try await game.scheduleNPCAction(action)
        case .stageNPCActions(let tick, let maximumActions):
            _ = try await game.stageNPCActions(to: tick, maximumActions: maximumActions)
        case .acknowledgeNPCActions(let actionIDs):
            _ = try await game.acknowledgeNPCActions(actionIDs)
        case .expireDisconnectedMembers(let now):
            _ = await game.expireDisconnectedMembers(now: now)
        case .finish(let extracted):
            try await game.finish(extracted: extracted)
        case .close:
            try await game.close()
        }
    }

    private static func encode(_ command: RedisDurableGameCoopCommand, commandID: UUID, maximumBytes: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(EncodedDurableCoopCommand(schemaVersion: 1, commandID: commandID, command: command))
        guard data.count <= maximumBytes else { throw GameServerError.stateTooLarge }
        return data
    }

    private static func decode(_ data: Data, maximumBytes: Int) throws -> EncodedDurableCoopCommand {
        guard data.count <= maximumBytes else { throw GameServerError.stateTooLarge }
        do {
            let encoded = try JSONDecoder().decode(EncodedDurableCoopCommand.self, from: data)
            guard encoded.schemaVersion == 1 else { throw GameServerError.invalidCheckpoint }
            return encoded
        }
        catch { throw GameServerError.invalidCheckpoint }
    }
}

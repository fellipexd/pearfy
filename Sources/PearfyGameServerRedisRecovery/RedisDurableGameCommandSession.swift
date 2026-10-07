import Crypto
import Foundation
import PearfyGameServer

public struct RedisDurableGameCommandConfiguration: Sendable, Equatable {
    public let maximumStateBytes: Int
    public let maximumCommandBytes: Int
    public let maximumProcessedCommands: Int
    public let maximumReplayEvents: Int
    public let maximumCheckpointBytes: Int
    public static let standard = RedisDurableGameCommandConfiguration(
        maximumStateBytes: 1_048_576, maximumCommandBytes: 65_536,
        maximumProcessedCommands: 10_000, maximumReplayEvents: 100_000,
        maximumCheckpointBytes: 16_777_216, standard: ()
    )

    public init(
        maximumStateBytes: Int = 1_048_576,
        maximumCommandBytes: Int = 65_536,
        maximumProcessedCommands: Int = 10_000,
        maximumReplayEvents: Int = 100_000,
        maximumCheckpointBytes: Int = 16_777_216
    ) throws {
        guard (1...16_777_216).contains(maximumStateBytes),
              (1...1_048_576).contains(maximumCommandBytes),
              (1...100_000).contains(maximumProcessedCommands),
              (1...1_000_000).contains(maximumReplayEvents),
              (1_024...268_435_456).contains(maximumCheckpointBytes) else {
            throw RedisGameStateRecoveryError.invalidConfiguration
        }
        self.maximumStateBytes = maximumStateBytes
        self.maximumCommandBytes = maximumCommandBytes
        self.maximumProcessedCommands = maximumProcessedCommands
        self.maximumReplayEvents = maximumReplayEvents
        self.maximumCheckpointBytes = maximumCheckpointBytes
    }

    private init(maximumStateBytes: Int, maximumCommandBytes: Int, maximumProcessedCommands: Int,
                 maximumReplayEvents: Int, maximumCheckpointBytes: Int, standard: Void) {
        self.maximumStateBytes = maximumStateBytes
        self.maximumCommandBytes = maximumCommandBytes
        self.maximumProcessedCommands = maximumProcessedCommands
        self.maximumReplayEvents = maximumReplayEvents
        self.maximumCheckpointBytes = maximumCheckpointBytes
    }
}

public struct RedisDurableGameCommandReceipt: Sendable, Equatable {
    public let sequence: UInt64
    public let isDuplicate: Bool
    /// Canonical result from the reducer. Filter it through the application's player
    /// visibility policy before sending anything to a client.
    public let state: Data
}

private struct RedisDurableCommandPayload: Codable, Sendable {
    let schemaVersion: UInt16
    let command: Data
}

private struct RedisDurableCommandLedgerEntry: Codable, Sendable {
    let commandID: UUID
    let playerID: UUID
    let digest: Data
    let sequence: UInt64
}

private struct RedisDurableCommandCheckpoint: Codable, Sendable {
    let schemaVersion: UInt16
    let revision: UInt64
    let state: Data
    let processedCommands: [RedisDurableCommandLedgerEntry]
}

/// A per-session, write-ahead command boundary for authoritative turn-based state.
/// The reducer runs against the last committed state, Redis append completes before
/// in-memory state changes, and retries with the same command ID are idempotent.
/// Call `commit` from an async command/control task, never from a simulation tick.
public actor RedisDurableGameCommandSession {
    public typealias Reducer = @Sendable (_ currentState: Data, _ playerID: UUID, _ command: Data) throws -> Data
    public typealias AsyncReducer = @Sendable (_ currentState: Data, _ playerID: UUID, _ command: Data) async throws -> Data

    private struct PreparedCommand {
        let event: GameStateEvent
        let digest: Data
    }

    private let sessionID: UUID
    private let lease: GameStateSessionLease
    private let store: any GameStateRecoveryStore
    private let configuration: RedisDurableGameCommandConfiguration
    private let reducer: AsyncReducer
    private var state: Data
    private var revision: UInt64
    private var ledger: [UUID: RedisDurableCommandLedgerEntry]
    private var ledgerOrder: [UUID]
    private var commitInProgress = false

    private init(
        sessionID: UUID,
        lease: GameStateSessionLease,
        store: any GameStateRecoveryStore,
        configuration: RedisDurableGameCommandConfiguration,
        reducer: @escaping AsyncReducer,
        state: Data,
        revision: UInt64,
        ledger: [UUID: RedisDurableCommandLedgerEntry],
        ledgerOrder: [UUID]
    ) {
        self.sessionID = sessionID
        self.lease = lease
        self.store = store
        self.configuration = configuration
        self.reducer = reducer
        self.state = state
        self.revision = revision
        self.ledger = ledger
        self.ledgerOrder = ledgerOrder
    }

    /// Opens a session only after the caller has acquired its Redis fencing lease.
    /// A fresh session requires `initialState`; a recovered session replays only the
    /// journal suffix after its last checkpoint and verifies each reducer result.
    public static func open(
        sessionID: UUID,
        lease: GameStateSessionLease,
        store: any GameStateRecoveryStore,
        initialState: Data? = nil,
        configuration: RedisDurableGameCommandConfiguration = .standard,
        reducer: @escaping Reducer
    ) async throws -> RedisDurableGameCommandSession {
        try await openAsync(
            sessionID: sessionID,
            lease: lease,
            store: store,
            initialState: initialState,
            configuration: configuration,
            reducer: { currentState, playerID, command in
                try reducer(currentState, playerID, command)
            }
        )
    }

    /// Async reducer variant for actor-backed domains such as `GameCoopSession`.
    /// Replay and commit remain serialized by this durable session actor; call it from
    /// a command/control task, never from the simulation tick.
    public static func openAsync(
        sessionID: UUID,
        lease: GameStateSessionLease,
        store: any GameStateRecoveryStore,
        initialState: Data? = nil,
        configuration: RedisDurableGameCommandConfiguration = .standard,
        reducer: @escaping AsyncReducer
    ) async throws -> RedisDurableGameCommandSession {
        guard lease.sessionID == sessionID, lease.epoch > 0 else {
            throw RedisGameStateRecoveryError.invalidConfiguration
        }
        if let recovered = try await store.load(sessionID: sessionID) {
            guard recovered.epoch == lease.epoch else { throw RedisGameStateRecoveryError.staleEpoch }
            guard recovered.checkpoint.events.isEmpty else { throw GameServerError.invalidCheckpoint }
            let checkpoint = try JSONDecoder().decode(RedisDurableCommandCheckpoint.self, from: recovered.checkpoint.state)
            guard checkpoint.schemaVersion == 1 else { throw RedisGameStateRecoveryError.unsupportedSnapshotVersion }
            guard checkpoint.revision == recovered.checkpoint.revision,
                  checkpoint.state.count <= configuration.maximumStateBytes,
                  checkpoint.processedCommands.count <= configuration.maximumProcessedCommands,
                  recovered.events.count <= configuration.maximumReplayEvents else {
                throw RedisGameStateRecoveryError.recoveryLimitExceeded
            }

            var state = checkpoint.state
            var revision = checkpoint.revision
            var ledger: [UUID: RedisDurableCommandLedgerEntry] = [:]
            var ledgerOrder: [UUID] = []
            var ledgerSequences = Set<UInt64>()
            var previousLedgerSequence: UInt64 = 0
            for entry in checkpoint.processedCommands {
                guard entry.digest.count == 32, entry.sequence > 0, entry.sequence <= checkpoint.revision,
                      entry.sequence > previousLedgerSequence,
                      ledger[entry.commandID] == nil, ledgerSequences.insert(entry.sequence).inserted else {
                    throw GameServerError.invalidCheckpoint
                }
                ledger[entry.commandID] = entry
                ledgerOrder.append(entry.commandID)
                previousLedgerSequence = entry.sequence
            }
            for event in recovered.events {
                guard revision < UInt64.max, event.sequence == revision + 1,
                      event.payload.count <= encodedCommandPayloadMaximumBytes(configuration.maximumCommandBytes),
                      event.state.count == 32,
                      ledger[event.commandID] == nil else { throw GameServerError.invalidCheckpoint }
                let payload = try JSONDecoder().decode(RedisDurableCommandPayload.self, from: event.payload)
                guard payload.schemaVersion == 1,
                      payload.command.count <= configuration.maximumCommandBytes else {
                    throw RedisGameStateRecoveryError.unsupportedSnapshotVersion
                }
                let next = try await reducer(state, event.playerID, payload.command)
                guard next.count <= configuration.maximumStateBytes,
                      Data(SHA256.hash(data: next)) == event.state else {
                    throw GameServerError.invalidCheckpoint
                }
                let entry = RedisDurableCommandLedgerEntry(
                    commandID: event.commandID,
                    playerID: event.playerID,
                    digest: Data(SHA256.hash(data: payload.command)),
                    sequence: event.sequence
                )
                appendToLedger(entry, ledger: &ledger, order: &ledgerOrder, maximum: configuration.maximumProcessedCommands)
                state = next
                revision = event.sequence
            }
            guard revision == recovered.latestSequence else { throw GameServerError.invalidCheckpoint }
            return RedisDurableGameCommandSession(
                sessionID: sessionID, lease: lease, store: store, configuration: configuration,
                reducer: reducer, state: state, revision: revision, ledger: ledger, ledgerOrder: ledgerOrder
            )
        }

        guard let initialState, initialState.count <= configuration.maximumStateBytes else {
            throw RedisGameStateRecoveryError.invalidResponse
        }
        let envelope = RedisDurableCommandCheckpoint(schemaVersion: 1, revision: 0, state: initialState, processedCommands: [])
        let data = try await encodeCheckpoint(envelope, maximumBytes: configuration.maximumCheckpointBytes)
        try await store.save(
            sessionID: sessionID,
            epoch: lease.epoch,
            checkpoint: GameStateCheckpoint(revision: 0, state: data, events: [])
        )
        return RedisDurableGameCommandSession(
            sessionID: sessionID, lease: lease, store: store, configuration: configuration,
            reducer: reducer, state: initialState, revision: 0, ledger: [:], ledgerOrder: []
        )
    }

    /// Appends the validated command and resulting state before changing this actor's
    /// committed state. An append error leaves memory unchanged; retry the same command
    /// ID to resolve an ambiguous network outcome safely.
    public func commit(
        commandID: UUID,
        playerID: UUID,
        command: Data,
        expectedRevision: UInt64? = nil
    ) async throws -> RedisDurableGameCommandReceipt {
        let digest = Data(SHA256.hash(data: command))
        if let previous = ledger[commandID] {
            guard previous.playerID == playerID, previous.digest == digest else {
                throw GameServerError.commandIDConflict
            }
            return RedisDurableGameCommandReceipt(sequence: previous.sequence, isDuplicate: true, state: state)
        }
        guard !commitInProgress else { throw RedisGameStateRecoveryError.commandCommitInProgress }
        guard command.count <= configuration.maximumCommandBytes else { throw GameServerError.stateTooLarge }
        if let expectedRevision, expectedRevision != revision {
            throw GameServerError.revisionConflict(current: revision)
        }
        guard revision < UInt64.max else { throw GameServerError.capacityReached }
        commitInProgress = true
        do {
            let next = try await reducer(state, playerID, command)
            guard next.count <= configuration.maximumStateBytes else { throw GameServerError.stateTooLarge }
            let payload = try Self.encodeCommand(command, maximumBytes: configuration.maximumCommandBytes)
            let stateDigest = Data(SHA256.hash(data: next))
            let event = GameStateEvent(sequence: revision + 1, commandID: commandID, playerID: playerID, payload: payload, state: stateDigest)
            let ledgerEntry = RedisDurableCommandLedgerEntry(commandID: commandID, playerID: playerID, digest: digest, sequence: event.sequence)
            try await store.append(sessionID: sessionID, epoch: lease.epoch, event: event)
            state = next
            revision = event.sequence
            Self.appendToLedger(ledgerEntry, ledger: &ledger, order: &ledgerOrder, maximum: configuration.maximumProcessedCommands)
            commitInProgress = false
            return RedisDurableGameCommandReceipt(sequence: event.sequence, isDuplicate: false, state: next)
        } catch {
            commitInProgress = false
            throw error
        }
    }

    /// Saves a bounded snapshot of the committed state and idempotency window. A
    /// failed save leaves the journal intact and can be retried without losing events.
    public func checkpoint() async throws {
        guard !commitInProgress else { throw RedisGameStateRecoveryError.commandCommitInProgress }
        commitInProgress = true
        let envelope = RedisDurableCommandCheckpoint(
            schemaVersion: 1,
            revision: revision,
            state: state,
            processedCommands: ledgerOrder.compactMap { ledger[$0] }
        )
        do {
            let checkpointState = try await Self.encodeCheckpoint(envelope, maximumBytes: configuration.maximumCheckpointBytes)
            try await store.save(
                sessionID: sessionID,
                epoch: lease.epoch,
                checkpoint: GameStateCheckpoint(revision: revision, state: checkpointState, events: [])
            )
            commitInProgress = false
        } catch {
            commitInProgress = false
            throw error
        }
    }

    public func snapshot() -> (revision: UInt64, state: Data) { (revision, state) }
    public var processedCommandCount: Int { ledger.count }

    private static func appendToLedger(
        _ entry: RedisDurableCommandLedgerEntry,
        ledger: inout [UUID: RedisDurableCommandLedgerEntry],
        order: inout [UUID],
        maximum: Int
    ) {
        if ledger.removeValue(forKey: entry.commandID) != nil {
            order.removeAll { $0 == entry.commandID }
        }
        while ledger.count >= maximum, let oldest = order.first {
            order.removeFirst()
            ledger.removeValue(forKey: oldest)
        }
        ledger[entry.commandID] = entry
        order.append(entry.commandID)
    }

    private static func encodeCommand(_ command: Data, maximumBytes: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(RedisDurableCommandPayload(schemaVersion: 1, command: command))
        guard command.count <= maximumBytes, data.count <= encodedCommandPayloadMaximumBytes(maximumBytes) else {
            throw GameServerError.stateTooLarge
        }
        return data
    }

    private static func encodedCommandPayloadMaximumBytes(_ commandBytes: Int) -> Int {
        // JSONEncoder represents Data as base64. Include its exact maximum expansion
        // and a small fixed allowance for the versioned envelope keys.
        ((commandBytes + 2) / 3) * 4 + 128
    }

    private static func encodeCheckpoint(
        _ checkpoint: RedisDurableCommandCheckpoint,
        maximumBytes: Int
    ) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(checkpoint)
            guard data.count <= maximumBytes else {
                throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: maximumBytes)
            }
            return data
        }.value
    }
}

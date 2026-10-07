import Foundation
import PearfyGameServer

/// One authoritative simulation tick. Transition payloads are application-defined,
/// server-authored records for movement, NPC actions, timers, inventory, or other
/// committed state changes. `randomDraws` records the exact draws the reducer uses.
public struct RedisDurableGameTick: Sendable, Codable, Equatable {
    public let number: UInt64
    public let transitions: [Data]
    public let randomDraws: [UInt64]

    public init(number: UInt64, transitions: [Data], randomDraws: [UInt64] = []) {
        self.number = number
        self.transitions = transitions
        self.randomDraws = randomDraws
    }
}

/// A bounded write-ahead unit. Several consecutive ticks share one Redis append;
/// the batch is not visible as committed until that append succeeds.
public struct RedisDurableGameTickBatch: Sendable, Codable, Equatable {
    public let id: UUID
    public let ticks: [RedisDurableGameTick]

    public init(id: UUID = UUID(), ticks: [RedisDurableGameTick]) {
        self.id = id
        self.ticks = ticks
    }
}

public struct RedisDurableGameTickConfiguration: Sendable, Equatable {
    public let maximumStateBytes: Int
    public let maximumTransitionBytes: Int
    public let maximumTransitionsPerTick: Int
    public let maximumRandomDrawsPerTick: Int
    public let maximumTicksPerBatch: Int
    public let maximumTransitionsPerBatch: Int
    public let maximumRandomDrawsPerBatch: Int
    public let maximumBatchBytes: Int
    public let maximumProcessedBatches: Int
    public let maximumReplayBatches: Int
    public let maximumCheckpointBytes: Int

    public static let standard = RedisDurableGameTickConfiguration(
        maximumStateBytes: 4_194_304,
        maximumTransitionBytes: 65_536,
        maximumTransitionsPerTick: 1_024,
        maximumRandomDrawsPerTick: 4_096,
        maximumTicksPerBatch: 120,
        maximumTransitionsPerBatch: 8_192,
        maximumRandomDrawsPerBatch: 8_192,
        maximumBatchBytes: 1_048_576,
        maximumProcessedBatches: 10_000,
        maximumReplayBatches: 100_000,
        maximumCheckpointBytes: 16_777_216,
        standard: ()
    )

    public init(
        maximumStateBytes: Int = 4_194_304,
        maximumTransitionBytes: Int = 65_536,
        maximumTransitionsPerTick: Int = 1_024,
        maximumRandomDrawsPerTick: Int = 4_096,
        maximumTicksPerBatch: Int = 120,
        maximumTransitionsPerBatch: Int = 8_192,
        maximumRandomDrawsPerBatch: Int = 8_192,
        maximumBatchBytes: Int = 1_048_576,
        maximumProcessedBatches: Int = 10_000,
        maximumReplayBatches: Int = 100_000,
        maximumCheckpointBytes: Int = 16_777_216
    ) throws {
        let (stateLedgerBytes, ledgerOverflow) = maximumProcessedBatches.multipliedReportingOverflow(by: 256)
        let (stateCheckpointBytes, stateOverflow) = maximumStateBytes.multipliedReportingOverflow(by: 2)
        let (ledgerAndHeaderBytes, headerOverflow) = stateLedgerBytes.addingReportingOverflow(1_024)
        let (minimumCheckpointBytes, checkpointOverflow) = stateCheckpointBytes.addingReportingOverflow(ledgerAndHeaderBytes)
        guard (1...8_000_000).contains(maximumStateBytes),
              (1...1_048_576).contains(maximumTransitionBytes),
              (1...4_096).contains(maximumTransitionsPerTick),
              (1...16_384).contains(maximumRandomDrawsPerTick),
              (1...120).contains(maximumTicksPerBatch),
              (1...65_536).contains(maximumTransitionsPerBatch),
              (1...65_536).contains(maximumRandomDrawsPerBatch),
              (256...1_048_576).contains(maximumBatchBytes),
              (1...100_000).contains(maximumProcessedBatches),
              (1...1_000_000).contains(maximumReplayBatches),
              (1_024...268_435_456).contains(maximumCheckpointBytes),
              !ledgerOverflow, !stateOverflow, !headerOverflow, !checkpointOverflow,
              maximumCheckpointBytes >= minimumCheckpointBytes else {
            throw RedisGameStateRecoveryError.invalidConfiguration
        }
        self.maximumStateBytes = maximumStateBytes
        self.maximumTransitionBytes = maximumTransitionBytes
        self.maximumTransitionsPerTick = maximumTransitionsPerTick
        self.maximumRandomDrawsPerTick = maximumRandomDrawsPerTick
        self.maximumTicksPerBatch = maximumTicksPerBatch
        self.maximumTransitionsPerBatch = maximumTransitionsPerBatch
        self.maximumRandomDrawsPerBatch = maximumRandomDrawsPerBatch
        self.maximumBatchBytes = maximumBatchBytes
        self.maximumProcessedBatches = maximumProcessedBatches
        self.maximumReplayBatches = maximumReplayBatches
        self.maximumCheckpointBytes = maximumCheckpointBytes
    }

    private init(
        maximumStateBytes: Int,
        maximumTransitionBytes: Int,
        maximumTransitionsPerTick: Int,
        maximumRandomDrawsPerTick: Int,
        maximumTicksPerBatch: Int,
        maximumTransitionsPerBatch: Int,
        maximumRandomDrawsPerBatch: Int,
        maximumBatchBytes: Int,
        maximumProcessedBatches: Int,
        maximumReplayBatches: Int,
        maximumCheckpointBytes: Int,
        standard: Void
    ) {
        self.maximumStateBytes = maximumStateBytes
        self.maximumTransitionBytes = maximumTransitionBytes
        self.maximumTransitionsPerTick = maximumTransitionsPerTick
        self.maximumRandomDrawsPerTick = maximumRandomDrawsPerTick
        self.maximumTicksPerBatch = maximumTicksPerBatch
        self.maximumTransitionsPerBatch = maximumTransitionsPerBatch
        self.maximumRandomDrawsPerBatch = maximumRandomDrawsPerBatch
        self.maximumBatchBytes = maximumBatchBytes
        self.maximumProcessedBatches = maximumProcessedBatches
        self.maximumReplayBatches = maximumReplayBatches
        self.maximumCheckpointBytes = maximumCheckpointBytes
    }
}

public struct RedisDurableGameTickReceipt: Sendable, Equatable {
    /// Journal revision counts committed batches, not individual simulation ticks.
    public let revision: UInt64
    public let lastCommittedTick: UInt64
    public let isDuplicate: Bool
    public let state: Data
}

public struct RedisDurableGameTickSnapshot: Sendable, Equatable {
    public let revision: UInt64
    public let lastCommittedTick: UInt64
    public let state: Data
}

private struct RedisDurableGameTickState: Codable, Sendable {
    let schemaVersion: UInt16
    let lastCommittedTick: UInt64
    let state: Data
}

private struct RedisDurableGameTickCommand: Codable, Sendable {
    let schemaVersion: UInt16
    let batch: RedisDurableGameTickBatch
}

private enum RedisDurableGameTickCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

/// Write-ahead recovery for server-authoritative simulation ticks. The application
/// reducer replays each tick in order; Redis persists one bounded event per batch,
/// including movement/NPC transitions and the RNG draws used by those transitions.
/// Call `commit` from a bounded async writer outside the simulation tick and publish
/// or acknowledge a batch only after its receipt succeeds.
public actor RedisDurableGameTickSession {
    public typealias AsyncReducer = @Sendable (_ currentState: Data, _ tick: RedisDurableGameTick) async throws -> Data

    private static let maximumEncodedStateBytes = 16_777_216
    private let sessionID: UUID
    private let durable: RedisDurableGameCommandSession
    private let configuration: RedisDurableGameTickConfiguration
    private var state: Data
    private var revision: UInt64
    private var lastCommittedTick: UInt64

    private init(
        sessionID: UUID,
        durable: RedisDurableGameCommandSession,
        configuration: RedisDurableGameTickConfiguration,
        state: Data,
        revision: UInt64,
        lastCommittedTick: UInt64
    ) {
        self.sessionID = sessionID
        self.durable = durable
        self.configuration = configuration
        self.state = state
        self.revision = revision
        self.lastCommittedTick = lastCommittedTick
    }

    /// Opens a new or recovered session after the caller has acquired its fencing
    /// lease. Recovery replays every uncheckpointed tick batch through `reducer`.
    public static func open(
        sessionID: UUID,
        lease: GameStateSessionLease,
        store: any GameStateRecoveryStore,
        initialState: Data? = nil,
        initialTick: UInt64 = 0,
        configuration: RedisDurableGameTickConfiguration = .standard,
        reducer: @escaping AsyncReducer
    ) async throws -> RedisDurableGameTickSession {
        guard lease.sessionID == sessionID, lease.epoch > 0 else {
            throw RedisGameStateRecoveryError.invalidConfiguration
        }
        let initialEnvelope: Data?
        if let initialState {
            guard initialState.count <= configuration.maximumStateBytes else { throw GameServerError.stateTooLarge }
            initialEnvelope = try RedisDurableGameTickCodec.encode(
                RedisDurableGameTickState(schemaVersion: 1, lastCommittedTick: initialTick, state: initialState)
            )
        } else {
            initialEnvelope = nil
        }

        let commandConfiguration = try RedisDurableGameCommandConfiguration(
            maximumStateBytes: Self.maximumEncodedStateBytes,
            maximumCommandBytes: configuration.maximumBatchBytes,
            maximumProcessedCommands: configuration.maximumProcessedBatches,
            maximumReplayEvents: configuration.maximumReplayBatches,
            maximumCheckpointBytes: configuration.maximumCheckpointBytes
        )
        let durable = try await RedisDurableGameCommandSession.openAsync(
            sessionID: sessionID,
            lease: lease,
            store: store,
            initialState: initialEnvelope,
            configuration: commandConfiguration,
            reducer: { encodedState, commandPlayerID, data in
                guard commandPlayerID == sessionID else { throw GameServerError.invalidCheckpoint }
                let current = try Self.decodeState(encodedState, maximumStateBytes: configuration.maximumStateBytes)
                let payload = try Self.decodeCommand(data, maximumBytes: configuration.maximumBatchBytes)
                try Self.validateBatch(payload.batch, configuration: configuration)

                var nextState = current.state
                var expectedTick = current.lastCommittedTick
                for tick in payload.batch.ticks {
                    guard expectedTick < UInt64.max else { throw GameServerError.capacityReached }
                    let nextTick = expectedTick + 1
                    guard tick.number == nextTick else {
                        throw RedisGameStateRecoveryError.tickSequenceConflict(expected: nextTick, actual: tick.number)
                    }
                    nextState = try await reducer(nextState, tick)
                    guard nextState.count <= configuration.maximumStateBytes else { throw GameServerError.stateTooLarge }
                    expectedTick = tick.number
                }
                return try RedisDurableGameTickCodec.encode(
                    RedisDurableGameTickState(schemaVersion: 1, lastCommittedTick: expectedTick, state: nextState)
                )
            }
        )
        let snapshot = await durable.snapshot()
        let recovered = try Self.decodeState(snapshot.state, maximumStateBytes: configuration.maximumStateBytes)
        return RedisDurableGameTickSession(
            sessionID: sessionID,
            durable: durable,
            configuration: configuration,
            state: recovered.state,
            revision: snapshot.revision,
            lastCommittedTick: recovered.lastCommittedTick
        )
    }

    /// Commits a contiguous batch in one journal append. The reducer and append are
    /// serialized with checkpointing; an append failure leaves the visible state and
    /// tick cursor unchanged. Retry an ambiguous result with the same batch ID.
    public func commit(
        _ batch: RedisDurableGameTickBatch,
        expectedRevision: UInt64? = nil
    ) async throws -> RedisDurableGameTickReceipt {
        try Self.validateBatch(batch, configuration: configuration)
        let command = try RedisDurableGameTickCodec.encode(RedisDurableGameTickCommand(schemaVersion: 1, batch: batch))
        guard command.count <= configuration.maximumBatchBytes else {
            throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: configuration.maximumBatchBytes)
        }
        let receipt = try await durable.commit(
            commandID: batch.id,
            playerID: sessionID,
            command: command,
            expectedRevision: expectedRevision
        )
        let committed = try Self.decodeState(receipt.state, maximumStateBytes: configuration.maximumStateBytes)
        state = committed.state
        revision = receipt.sequence
        lastCommittedTick = committed.lastCommittedTick
        return RedisDurableGameTickReceipt(
            revision: receipt.sequence,
            lastCommittedTick: committed.lastCommittedTick,
            isDuplicate: receipt.isDuplicate,
            state: committed.state
        )
    }

    /// Captures the last committed application state. Staged/uncommitted ticks are
    /// intentionally absent.
    public func snapshot() -> RedisDurableGameTickSnapshot {
        RedisDurableGameTickSnapshot(revision: revision, lastCommittedTick: lastCommittedTick, state: state)
    }

    public func checkpoint() async throws {
        try await durable.checkpoint()
    }

    static func validateBatch(
        _ batch: RedisDurableGameTickBatch,
        configuration: RedisDurableGameTickConfiguration
    ) throws {
        guard !batch.ticks.isEmpty, batch.ticks.count <= configuration.maximumTicksPerBatch else {
            throw RedisGameStateRecoveryError.tickBatchLimitExceeded
        }
        var transitions = 0
        var randomDraws = 0
        var transitionBytes = 0
        // Conservative JSON budget, including the outer versioned command envelope.
        // Staging uses this arithmetic-only estimate and never serializes on the tick path.
        var estimatedEncodedBytes = 192
        for (index, tick) in batch.ticks.enumerated() {
            guard tick.transitions.count <= configuration.maximumTransitionsPerTick,
                  tick.randomDraws.count <= configuration.maximumRandomDrawsPerTick else {
                throw RedisGameStateRecoveryError.tickBatchLimitExceeded
            }
            let (nextTransitions, transitionOverflow) = transitions.addingReportingOverflow(tick.transitions.count)
            guard !transitionOverflow, nextTransitions <= configuration.maximumTransitionsPerBatch else {
                throw RedisGameStateRecoveryError.tickBatchLimitExceeded
            }
            transitions = nextTransitions
            let (nextRandomDraws, randomOverflow) = randomDraws.addingReportingOverflow(tick.randomDraws.count)
            guard !randomOverflow, nextRandomDraws <= configuration.maximumRandomDrawsPerBatch else {
                throw RedisGameStateRecoveryError.tickBatchLimitExceeded
            }
            randomDraws = nextRandomDraws
            let (estimatedTickBytes, tickOverflow) = estimatedEncodedBytes.addingReportingOverflow(64)
            guard !tickOverflow, estimatedTickBytes <= configuration.maximumBatchBytes else {
                throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: configuration.maximumBatchBytes)
            }
            estimatedEncodedBytes = estimatedTickBytes
            for payload in tick.transitions {
                guard payload.count <= configuration.maximumTransitionBytes else {
                    throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: configuration.maximumTransitionBytes)
                }
                let (nextBytes, byteOverflow) = transitionBytes.addingReportingOverflow(payload.count)
                guard !byteOverflow, nextBytes <= configuration.maximumBatchBytes else {
                    throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: configuration.maximumBatchBytes)
                }
                transitionBytes = nextBytes
                let (base64Numerator, numeratorOverflow) = payload.count.addingReportingOverflow(2)
                guard !numeratorOverflow else { throw RedisGameStateRecoveryError.tickBatchLimitExceeded }
                let (base64Bytes, base64Overflow) = (base64Numerator / 3).multipliedReportingOverflow(by: 4)
                let (itemBytes, itemOverflow) = base64Bytes.addingReportingOverflow(3)
                let (nextEstimate, estimateOverflow) = estimatedEncodedBytes.addingReportingOverflow(itemBytes)
                guard !base64Overflow, !itemOverflow, !estimateOverflow,
                      nextEstimate <= configuration.maximumBatchBytes else {
                    throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: configuration.maximumBatchBytes)
                }
                estimatedEncodedBytes = nextEstimate
            }
            for _ in tick.randomDraws {
                let (nextEstimate, estimateOverflow) = estimatedEncodedBytes.addingReportingOverflow(21)
                guard !estimateOverflow, nextEstimate <= configuration.maximumBatchBytes else {
                    throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: configuration.maximumBatchBytes)
                }
                estimatedEncodedBytes = nextEstimate
            }
            if index > 0 {
                let previous = batch.ticks[index - 1].number
                guard previous < UInt64.max, tick.number == previous + 1 else {
                    throw RedisGameStateRecoveryError.invalidTickBatch
                }
            }
        }
    }

    static func retainedByteEstimate(for batch: RedisDurableGameTickBatch) throws -> Int {
        var bytes = 256
        for tick in batch.ticks {
            let (tickBytes, tickOverflow) = bytes.addingReportingOverflow(64)
            guard !tickOverflow else { throw RedisGameStateRecoveryError.tickBatchLimitExceeded }
            bytes = tickBytes
            for transition in tick.transitions {
                let (itemBytes, itemOverflow) = transition.count.addingReportingOverflow(32)
                let (nextBytes, totalOverflow) = bytes.addingReportingOverflow(itemBytes)
                guard !itemOverflow, !totalOverflow else { throw RedisGameStateRecoveryError.tickBatchLimitExceeded }
                bytes = nextBytes
            }
            let (randomBytes, randomOverflow) = tick.randomDraws.count.multipliedReportingOverflow(by: 8)
            let (nextBytes, totalOverflow) = bytes.addingReportingOverflow(randomBytes)
            guard !randomOverflow, !totalOverflow else { throw RedisGameStateRecoveryError.tickBatchLimitExceeded }
            bytes = nextBytes
        }
        return bytes
    }

    private static func decodeCommand(_ data: Data, maximumBytes: Int) throws -> RedisDurableGameTickCommand {
        guard data.count <= maximumBytes else { throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: maximumBytes) }
        let command = try JSONDecoder().decode(RedisDurableGameTickCommand.self, from: data)
        guard command.schemaVersion == 1 else { throw RedisGameStateRecoveryError.unsupportedSnapshotVersion }
        return command
    }

    private static func decodeState(_ data: Data, maximumStateBytes: Int) throws -> RedisDurableGameTickState {
        guard data.count <= maximumEncodedStateBytes else {
            throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: maximumEncodedStateBytes)
        }
        let state = try JSONDecoder().decode(RedisDurableGameTickState.self, from: data)
        guard state.schemaVersion == 1 else { throw RedisGameStateRecoveryError.unsupportedSnapshotVersion }
        guard state.state.count <= maximumStateBytes else { throw GameServerError.stateTooLarge }
        return state
    }

    /// Creates a finite in-memory staging queue. Call `stage` from the simulation
    /// producer, then drain it from a separate async writer task using `commitNext`.
    public func makeBoundedQueue(
        maximumPendingBatches: Int = 32,
        maximumPendingBytes: Int = 16_777_216
    ) throws -> RedisDurableGameTickBatchQueue {
        try RedisDurableGameTickBatchQueue(
            session: self,
            configuration: configuration,
            lastCommittedTick: lastCommittedTick,
            maximumPendingBatches: maximumPendingBatches,
            maximumPendingBytes: maximumPendingBytes
        )
    }
}

public struct RedisDurableGameTickQueueMetrics: Sendable, Equatable {
    public let pendingBatchCount: Int
    public let pendingBytes: Int
    public let isCommitting: Bool
}

/// A finite, newest-order queue between a serialized tick producer and the async
/// Redis writer. `stage` performs validation and bounded memory bookkeeping only.
/// `commitNext` removes a batch only after durable success; an error leaves the same
/// batch at the head so the caller can retry its idempotency key or stop the session.
public actor RedisDurableGameTickBatchQueue {
    private struct PendingBatch {
        let batch: RedisDurableGameTickBatch
        let retainedBytes: Int
    }

    private let session: RedisDurableGameTickSession
    private let configuration: RedisDurableGameTickConfiguration
    private let maximumPendingBatches: Int
    private let maximumPendingBytes: Int
    private var pending: [PendingBatch] = []
    private var pendingIDs: Set<UUID> = []
    private var pendingBytes = 0
    private var lastQueuedTick: UInt64
    private var isCommitting = false
    private let notificationStream: AsyncStream<Void>
    private let notificationContinuation: AsyncStream<Void>.Continuation

    fileprivate init(
        session: RedisDurableGameTickSession,
        configuration: RedisDurableGameTickConfiguration,
        lastCommittedTick: UInt64,
        maximumPendingBatches: Int,
        maximumPendingBytes: Int
    ) throws {
        guard (1...100_000).contains(maximumPendingBatches),
              (1...268_435_456).contains(maximumPendingBytes) else {
            throw RedisGameStateRecoveryError.invalidConfiguration
        }
        self.session = session
        self.configuration = configuration
        self.lastQueuedTick = lastCommittedTick
        self.maximumPendingBatches = maximumPendingBatches
        self.maximumPendingBytes = maximumPendingBytes
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.notificationStream = stream
        self.notificationContinuation = continuation
    }

    /// Stages one complete authoritative unit without waiting for Redis I/O.
    /// Producers must be serialized and must stop/adapt when this throws capacity.
    public func stage(_ batch: RedisDurableGameTickBatch) throws {
        try RedisDurableGameTickSession.validateBatch(batch, configuration: configuration)
        guard !pendingIDs.contains(batch.id) else { throw RedisGameStateRecoveryError.tickBatchAlreadyQueued }
        guard lastQueuedTick < UInt64.max,
              let first = batch.ticks.first,
              first.number == lastQueuedTick + 1 else {
            let actual = batch.ticks.first?.number ?? 0
            let expected = lastQueuedTick == UInt64.max ? UInt64.max : lastQueuedTick + 1
            throw RedisGameStateRecoveryError.tickSequenceConflict(expected: expected, actual: actual)
        }
        let bytes = try RedisDurableGameTickSession.retainedByteEstimate(for: batch)
        let (nextBytes, overflow) = pendingBytes.addingReportingOverflow(bytes)
        guard pending.count < maximumPendingBatches,
              bytes <= maximumPendingBytes,
              !overflow, nextBytes <= maximumPendingBytes else {
            throw RedisGameStateRecoveryError.tickQueueCapacityReached
        }
        pending.append(PendingBatch(batch: batch, retainedBytes: bytes))
        pendingIDs.insert(batch.id)
        pendingBytes = nextBytes
        lastQueuedTick = batch.ticks[batch.ticks.count - 1].number
        notificationContinuation.yield(())
    }

    /// Commits the oldest staged batch. A single writer should call this method in a
    /// loop; concurrent drainers receive `commandCommitInProgress`.
    public func commitNext() async throws -> RedisDurableGameTickReceipt? {
        guard !isCommitting else { throw RedisGameStateRecoveryError.commandCommitInProgress }
        guard let first = pending.first else { return nil }
        isCommitting = true
        do {
            let receipt = try await session.commit(first.batch)
            guard pending.first?.batch.id == first.batch.id else {
                isCommitting = false
                throw RedisGameStateRecoveryError.invalidResponse
            }
            pending.removeFirst()
            pendingIDs.remove(first.batch.id)
            pendingBytes -= first.retainedBytes
            if pending.isEmpty { lastQueuedTick = receipt.lastCommittedTick }
            isCommitting = false
            return receipt
        } catch {
            isCommitting = false
            throw error
        }
    }

    public func metrics() -> RedisDurableGameTickQueueMetrics {
        RedisDurableGameTickQueueMetrics(
            pendingBatchCount: pending.count,
            pendingBytes: pendingBytes,
            isCommitting: isCommitting
        )
    }

    /// A single-consumer wake-up stream. It carries no batch data; the bounded actor
    /// queue remains the source of truth. The one-slot buffer coalesces notifications.
    public func pendingBatchNotifications() -> AsyncStream<Void> { notificationStream }

    /// Re-wakes the writer after an append failure has been handled externally.
    /// The failed batch remains at the head and is retried with the same batch ID.
    public func retryPending() {
        if !pending.isEmpty { notificationContinuation.yield(()) }
    }
}

import Foundation
import PearfyGameServer

public struct GameStateRecoveryCheckpointSchedulerMetrics: Sendable, Equatable {
    public let successfulCheckpoints: UInt64
    public let failedCheckpoints: UInt64
    public let lastSuccessfulCheckpointAt: Date?
    public let isRunning: Bool
}

public enum GameStateRecoveryCheckpointSchedulerError: Error, Sendable, Equatable {
    case invalidConfiguration
    case alreadyRunning
    case checkpointInProgress
    case checkpointTooLarge(maximumBytes: Int)
}

/// Periodically captures authoritative state and checkpoints it outside the game tick.
/// The application supplies the matching journal watermark and remains responsible for
/// publishing accepted events before the checkpoint can cover them.
public actor GameStateRecoveryCheckpointScheduler {
    public typealias Capture = @Sendable () async throws -> GameStateCheckpoint

    private let store: any GameStateRecoveryStore
    private let sessionID: UUID
    private let epoch: UInt64
    private let intervalMilliseconds: Int64
    private let maximumCheckpointBytes: Int
    private let capture: Capture
    private var worker: Task<Void, Never>?
    private var checkpointInProgress = false
    private var successfulCheckpoints: UInt64 = 0
    private var failedCheckpoints: UInt64 = 0
    private var lastSuccessfulCheckpointAt: Date?

    public init(
        store: any GameStateRecoveryStore,
        sessionID: UUID,
        epoch: UInt64,
        intervalMilliseconds: Int64,
        maximumCheckpointBytes: Int = 16_777_216,
        capture: @escaping Capture
    ) throws {
        guard epoch > 0, (100...86_400_000).contains(intervalMilliseconds),
              (1...67_108_864).contains(maximumCheckpointBytes) else {
            throw GameStateRecoveryCheckpointSchedulerError.invalidConfiguration
        }
        self.store = store
        self.sessionID = sessionID
        self.epoch = epoch
        self.intervalMilliseconds = intervalMilliseconds
        self.maximumCheckpointBytes = maximumCheckpointBytes
        self.capture = capture
    }

    public func start() throws {
        guard worker == nil else { throw GameStateRecoveryCheckpointSchedulerError.alreadyRunning }
        worker = Task { [weak self] in
            await self?.run()
        }
    }

    /// Captures and writes one checkpoint. Call from an async maintenance task, not a tick.
    public func checkpointNow() async throws {
        guard !checkpointInProgress else {
            throw GameStateRecoveryCheckpointSchedulerError.checkpointInProgress
        }
        checkpointInProgress = true
        do {
            let checkpoint = try await capture()
            guard checkpoint.state.count <= maximumCheckpointBytes else {
                throw GameStateRecoveryCheckpointSchedulerError.checkpointTooLarge(maximumBytes: maximumCheckpointBytes)
            }
            try await store.save(sessionID: sessionID, epoch: epoch, checkpoint: checkpoint)
            successfulCheckpoints &+= 1
            lastSuccessfulCheckpointAt = Date()
            checkpointInProgress = false
        } catch {
            failedCheckpoints &+= 1
            checkpointInProgress = false
            throw error
        }
    }

    /// Stops future captures. Call `checkpointNow()` first when shutdown requires a final snapshot.
    public func stop() async {
        guard let currentWorker = worker else { return }
        worker = nil
        currentWorker.cancel()
        await currentWorker.value
    }

    public func metrics() -> GameStateRecoveryCheckpointSchedulerMetrics {
        GameStateRecoveryCheckpointSchedulerMetrics(
            successfulCheckpoints: successfulCheckpoints,
            failedCheckpoints: failedCheckpoints,
            lastSuccessfulCheckpointAt: lastSuccessfulCheckpointAt,
            isRunning: worker != nil
        )
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(intervalMilliseconds))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            do {
                try await checkpointNow()
            } catch {
                // Failure details may contain application state; expose only a counter.
            }
        }
    }
}

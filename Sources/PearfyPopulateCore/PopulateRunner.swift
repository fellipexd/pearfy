import Foundation

public enum PopulateRunStatus: String, Codable, Sendable {
    case running
    case partial
    case complete
    case cancelled
}

public struct PopulateRunState: Codable, Equatable, Sendable {
    public let runID: String
    public let planHash: String
    public let schemaFingerprint: String
    public var status: PopulateRunStatus
    public var nextRowOrdinal: Int
    public var processedRows: Int
    public var insertedRows: Int
    public var initialSizeBytes: Int64
    public var latestSizeBytes: Int64
    public var startedAt: Date
    public var stopReason: String?
    public var lastError: String?

    public init(plan: PopulatePlan, startedAt: Date = Date()) {
        runID = plan.id
        planHash = plan.planHash
        schemaFingerprint = plan.schemaFingerprint
        status = .running
        nextRowOrdinal = 0
        processedRows = 0
        insertedRows = 0
        initialSizeBytes = plan.initialSizeBytes
        latestSizeBytes = plan.initialSizeBytes
        self.startedAt = startedAt
        stopReason = nil
        lastError = nil
    }
}

public struct PopulateBatchResult: Equatable, Sendable {
    public let insertedRows: Int
    public let measuredSizeBytes: Int64?

    public init(insertedRows: Int, measuredSizeBytes: Int64? = nil) {
        self.insertedRows = insertedRows
        self.measuredSizeBytes = measuredSizeBytes
    }
}

public protocol PopulateExecutionStore: Sendable {
    /// Implementations must generate identical values for the same plan and
    /// ordinal range and should make replays idempotent using generated keys.
    func insertRows(plan: PopulatePlan, ordinals: Range<Int>) async throws -> PopulateBatchResult
}

public protocol PopulateRunRegistry: Sendable {
    func load(runID: String) async throws -> PopulateRunState?
    func save(_ state: PopulateRunState) async throws
}

public enum PopulateExecutionError: Error, Sendable, Equatable, CustomStringConvertible {
    case approvalMismatch
    case schemaChanged(expected: String, actual: String)
    case runPlanMismatch
    case invalidState

    public var description: String {
        switch self {
        case .approvalMismatch: "PEARFY_POPULATE_015: approval hash does not match this plan"
        case .schemaChanged(let expected, let actual): "PEARFY_POPULATE_016: schema changed after planning (expected \(expected), found \(actual))"
        case .runPlanMismatch: "PEARFY_POPULATE_017: checkpoint belongs to a different plan or schema"
        case .invalidState: "PEARFY_POPULATE_018: run checkpoint is invalid"
        }
    }
}

public struct PopulateRunner: Sendable {
    public init() {}

    /// Executes bounded committed batches. On a batch error it persists the
    /// honest checkpoint and returns `.partial`; completed batches remain
    /// committed and are never described as globally rolled back.
    public func execute(
        plan: PopulatePlan,
        approvalHash: String,
        currentSchemaFingerprint: String,
        store: any PopulateExecutionStore,
        registry: any PopulateRunRegistry,
        batchLimit: Int? = nil,
        currentSizeBytes: Int64? = nil
    ) async throws -> PopulateRunState {
        guard constantTimeEqual(plan.planHash, approvalHash) else { throw PopulateExecutionError.approvalMismatch }
        guard plan.schemaFingerprint == currentSchemaFingerprint else {
            throw PopulateExecutionError.schemaChanged(expected: plan.schemaFingerprint, actual: currentSchemaFingerprint)
        }

        var state = try await registry.load(runID: plan.id) ?? PopulateRunState(plan: plan)
        guard state.runID == plan.id,
              state.planHash == plan.planHash,
              state.schemaFingerprint == currentSchemaFingerprint,
              (0...plan.rowCount).contains(state.nextRowOrdinal),
              state.processedRows >= 0,
              state.insertedRows >= 0 else {
            throw PopulateExecutionError.runPlanMismatch
        }
        if state.status == .complete { return state }
        if let currentSizeBytes {
            state.latestSizeBytes = max(0, currentSizeBytes)
            if let target = plan.targetSizeBytes, state.latestSizeBytes >= target {
                state.status = .complete
                state.stopReason = "target size already reached before this execution"
                try await registry.save(state)
                return state
            }
        }
        if state.status == .partial && state.nextRowOrdinal == plan.rowCount { return state }
        if state.status == .cancelled { state.status = .running; state.stopReason = nil }
        state.status = .running
        state.lastError = nil
        try await registry.save(state)

        var batches = 0
        while state.nextRowOrdinal < plan.rowCount {
            if Task.isCancelled {
                state.status = .cancelled
                state.stopReason = "cancelled by caller"
                try await registry.save(state)
                return state
            }
            let elapsed = Date().timeIntervalSince(state.startedAt)
            if elapsed >= Double(plan.limits.maxDurationSeconds) {
                state.status = .partial
                state.stopReason = "maximum duration reached"
                try await registry.save(state)
                return state
            }
            if batches >= (batchLimit ?? .max) {
                state.status = .partial
                state.stopReason = "execution yielded after \(batches) batches"
                try await registry.save(state)
                return state
            }

            var batchSize = plan.limits.maxBatchRows
            if let targetBytes = plan.targetSizeBytes {
                let remainingBytes = max(0, targetBytes - state.latestSizeBytes)
                let estimatedRows = remainingBytes / plan.estimatedBytesPerRow
                    + (remainingBytes % plan.estimatedBytesPerRow == 0 ? 0 : 1)
                batchSize = min(batchSize, max(1, Int(min(Int64(batchSize), estimatedRows))))
            }
            let end = min(plan.rowCount, state.nextRowOrdinal + batchSize)
            let range = state.nextRowOrdinal..<end
            var result: PopulateBatchResult?
            var lastError: String?
            for attempt in 0...plan.limits.maxRetries {
                do {
                    result = try await store.insertRows(plan: plan, ordinals: range)
                    lastError = nil
                    break
                } catch {
                    lastError = String(describing: error)
                    if attempt < plan.limits.maxRetries {
                        try? await Task.sleep(for: .milliseconds(50 * (1 << attempt)))
                    }
                }
            }
            guard let result else {
                state.status = .partial
                state.lastError = lastError ?? "batch failed"
                state.stopReason = "batch \(state.processedRows / plan.limits.maxBatchRows) failed; earlier batches are committed"
                try await registry.save(state)
                return state
            }

            state.nextRowOrdinal = end
            state.processedRows += range.count
            state.insertedRows += max(0, result.insertedRows)
            if let measuredSize = result.measuredSizeBytes { state.latestSizeBytes = measuredSize }
            state.lastError = nil
            batches += 1

            if let targetBytes = plan.targetSizeBytes, state.latestSizeBytes >= targetBytes {
                state.status = .complete
                state.stopReason = "target size reached"
            } else if end == plan.rowCount {
                if plan.targetSizeBytes != nil {
                    state.status = .partial
                    state.stopReason = "planned row bound reached before target size"
                } else {
                    state.status = .complete
                    state.stopReason = "planned row count completed"
                }
            }
            try await registry.save(state)
            if state.status != .running { return state }
        }
        state.status = .complete
        state.stopReason = state.stopReason ?? "planned row count completed"
        try await registry.save(state)
        return state
    }

    private func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let lhs = Array(left.utf8)
        let rhs = Array(right.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (leftByte, rightByte) in zip(lhs, rhs) { difference |= leftByte ^ rightByte }
        return difference == 0
    }
}

public actor FilePopulateRunRegistry: PopulateRunRegistry {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(runID: String) throws -> PopulateRunState? {
        guard Self.isSafeRunID(runID) else { throw PopulateExecutionError.invalidState }
        let url = directory.appendingPathComponent("\(runID).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(PopulateRunState.self, from: Data(contentsOf: url))
        } catch {
            throw PopulateExecutionError.invalidState
        }
    }

    public func save(_ state: PopulateRunState) throws {
        guard Self.isSafeRunID(state.runID) else { throw PopulateExecutionError.invalidState }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(state) + Data([0x0a])).write(
            to: directory.appendingPathComponent("\(state.runID).json"),
            options: .atomic
        )
    }

    private static func isSafeRunID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...122).contains($0) || $0 == 45
        }
    }
}

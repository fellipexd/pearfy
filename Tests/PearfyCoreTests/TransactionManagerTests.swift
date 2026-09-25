import Foundation
import PearfyTransactions
import Testing

@Test func transactionManagerRequiredPropagationReusesOneUnitOfWork() async throws {
    let store = RecordingTransactionalStore()
    let manager = PearfyTransactionManager(store: store)

    let result = try await manager.withTransaction { outer in
        try await manager.withTransaction { inner in
            #expect(inner.id == outer.id)
            return "shared"
        }
    }

    #expect(result == "shared")
    #expect(await store.stats() == TransactionStoreStats(begins: 1, commits: 1, rollbacks: 0, unknownCommits: 0))
}

@Test func transactionManagerMarksRollbackOnlyWhenNestedFailureIsCaught() async throws {
    let store = RecordingTransactionalStore()
    let manager = PearfyTransactionManager(store: store)
    var rollbackOnlyObserved = false

    do {
        _ = try await manager.withTransaction { outer in
            do {
                _ = try await manager.withTransaction { inner in
                    #expect(inner.id == outer.id)
                    throw TransactionTestFailure.nestedOperation
                }
            } catch TransactionTestFailure.nestedOperation {
                // The caller catches the operation error; the transaction remains rollback-only.
            }
            return "must not commit"
        }
    } catch TransactionManagerError.rollbackOnly {
        rollbackOnlyObserved = true
    }

    #expect(rollbackOnlyObserved)
    #expect(await store.stats() == TransactionStoreStats(begins: 1, commits: 0, rollbacks: 1, unknownCommits: 0))
}

@Test func transactionManagerDoesNotRetryUnknownCommit() async throws {
    let store = RecordingTransactionalStore(commitOutcomeUnknown: true)
    let manager = PearfyTransactionManager(store: store)
    var unknownCommitObserved = false

    do {
        _ = try await manager.withTransaction { _ in "write completed" }
    } catch is TransactionCommitOutcomeUnknown {
        unknownCommitObserved = true
    }

    #expect(unknownCommitObserved)
    #expect(await store.stats() == TransactionStoreStats(begins: 1, commits: 0, rollbacks: 0, unknownCommits: 1))
}

@Test func transactionManagerRejectsUnsupportedPropagationAndCrossManagerNesting() async throws {
    let store = RecordingTransactionalStore()
    let manager = PearfyTransactionManager(store: store)
    var unsupportedPropagationRejected = false
    do {
        _ = try await manager.withTransaction(propagation: .requiresNew) { _ in true }
    } catch TransactionManagerError.unsupportedPropagation(.requiresNew) {
        unsupportedPropagationRejected = true
    }
    #expect(unsupportedPropagationRejected)
    #expect(await store.stats().begins == 0)

    let otherManager = PearfyTransactionManager(store: store)
    var crossManagerRejected = false
    do {
        _ = try await manager.withTransaction { _ in
            try await otherManager.withTransaction { _ in true }
        }
    } catch TransactionManagerError.nestedTransactionUsesDifferentManager {
        crossManagerRejected = true
    }
    #expect(crossManagerRejected)
    #expect(await store.stats() == TransactionStoreStats(begins: 1, commits: 0, rollbacks: 1, unknownCommits: 0))
}

@Test func transactionManagerCancellationRollsBackTheStoreUnit() async throws {
    let store = RecordingTransactionalStore()
    let manager = PearfyTransactionManager(store: store)
    var cancellationObserved = false

    do {
        _ = try await manager.withTransaction { _ in throw CancellationError() }
    } catch is CancellationError {
        cancellationObserved = true
    }

    #expect(cancellationObserved)
    #expect(await store.stats() == TransactionStoreStats(begins: 1, commits: 0, rollbacks: 1, unknownCommits: 0))
}

private struct RecordingUnitOfWork: Sendable, Equatable {
    let id: UUID
}

private struct TransactionStoreStats: Sendable, Equatable {
    let begins: Int
    let commits: Int
    let rollbacks: Int
    let unknownCommits: Int
}

private actor RecordingTransactionalStore: PearfyTransactionalStore {
    typealias UnitOfWork = RecordingUnitOfWork

    private let commitOutcomeUnknown: Bool
    private var begins = 0
    private var commits = 0
    private var rollbacks = 0
    private var unknownCommits = 0

    init(commitOutcomeUnknown: Bool = false) {
        self.commitOutcomeUnknown = commitOutcomeUnknown
    }

    func withTransaction<Value: Sendable>(
        transactionID: UUID,
        _ operation: @Sendable (RecordingUnitOfWork) async throws -> Value
    ) async throws -> Value {
        begins += 1
        do {
            let value = try await operation(RecordingUnitOfWork(id: transactionID))
            if commitOutcomeUnknown {
                unknownCommits += 1
                throw TransactionCommitOutcomeUnknown(
                    transactionID: transactionID,
                    reason: "simulated lost commit acknowledgement"
                )
            }
            commits += 1
            return value
        } catch let error as TransactionCommitOutcomeUnknown {
            throw error
        } catch {
            rollbacks += 1
            throw error
        }
    }

    func stats() -> TransactionStoreStats {
        TransactionStoreStats(
            begins: begins,
            commits: commits,
            rollbacks: rollbacks,
            unknownCommits: unknownCommits
        )
    }
}

private enum TransactionTestFailure: Error, Sendable {
    case nestedOperation
}

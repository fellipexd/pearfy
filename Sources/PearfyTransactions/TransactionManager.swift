import Foundation

public enum TransactionPropagation: Sendable, Equatable {
    case required
    case requiresNew
    case nested
}

/// A store must throw this error when a COMMIT was attempted but the adapter
/// cannot determine whether the database committed it. The store must release
/// or discard its connection before throwing; callers must reconcile before retrying.
public struct TransactionCommitOutcomeUnknown: Error, Sendable, Equatable, CustomStringConvertible {
    public let transactionID: UUID
    public let reason: String

    public init(transactionID: UUID, reason: String) {
        self.transactionID = transactionID
        self.reason = reason
    }

    public var description: String {
        "PEARFY_TX_001: commit outcome is unknown for transaction \(transactionID): \(reason)"
    }
}

public enum TransactionManagerError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedPropagation(TransactionPropagation)
    case nestedTransactionUsesDifferentManager
    case transactionUnitOfWorkTypeMismatch
    case rollbackOnly(UUID)

    public var description: String {
        switch self {
        case .unsupportedPropagation(let propagation):
            "PEARFY_TX_002: propagation '\(propagation)' is not implemented by this manager"
        case .nestedTransactionUsesDifferentManager:
            "PEARFY_TX_003: nested scopes across different transaction managers are unsupported"
        case .transactionUnitOfWorkTypeMismatch:
            "PEARFY_TX_004: active transaction unit of work does not match the requested store"
        case .rollbackOnly(let transactionID):
            "PEARFY_TX_005: transaction \(transactionID) was marked rollback-only"
        }
    }
}

/// A storage adapter must wrap the complete callback in one physical
/// transaction: normal return commits, thrown errors/cancellation roll back,
/// and ambiguous commit failures throw `TransactionCommitOutcomeUnknown`. A unit
/// is bound to that transaction and must not be used concurrently from child
/// tasks unless the adapter explicitly serializes that access.
public protocol PearfyTransactionalStore: Sendable {
    associatedtype UnitOfWork: Sendable

    func withTransaction<Value: Sendable>(
        transactionID: UUID,
        _ operation: @Sendable (UnitOfWork) async throws -> Value
    ) async throws -> Value
}

/// Coordinates REQUIRED propagation over a store-provided physical unit of
/// work. Nested calls share that exact unit; errors mark it rollback-only even
/// if a caller catches the original error. Other propagation modes fail closed.
/// Task-local propagation is not permission to use the unit from parallel child tasks.
public struct PearfyTransactionManager<Store: PearfyTransactionalStore>: Sendable {
    public let store: Store
    private let managerID: UUID

    public init(store: Store) {
        self.store = store
        managerID = UUID()
    }

    public func withTransaction<Value: Sendable>(
        propagation: TransactionPropagation = .required,
        _ operation: @Sendable (Store.UnitOfWork) async throws -> Value
    ) async throws -> Value {
        guard propagation == .required else {
            if let active = TransactionScope.current, active.managerID == managerID {
                await active.rollbackState.markRollbackOnly()
            }
            throw TransactionManagerError.unsupportedPropagation(propagation)
        }

        if let active = TransactionScope.current {
            guard active.managerID == managerID else {
                await active.rollbackState.markRollbackOnly()
                throw TransactionManagerError.nestedTransactionUsesDifferentManager
            }
            guard let unitOfWork = active.unitOfWork as? Store.UnitOfWork else {
                await active.rollbackState.markRollbackOnly()
                throw TransactionManagerError.transactionUnitOfWorkTypeMismatch
            }

            do {
                let value = try await operation(unitOfWork)
                if await active.rollbackState.isRollbackOnly {
                    throw TransactionManagerError.rollbackOnly(active.transactionID)
                }
                return value
            } catch {
                await active.rollbackState.markRollbackOnly()
                throw error
            }
        }

        let transactionID = UUID()
        return try await store.withTransaction(transactionID: transactionID) { unitOfWork in
            let rollbackState = TransactionRollbackState()
            let frame = TransactionFrame(
                managerID: managerID,
                transactionID: transactionID,
                unitOfWork: unitOfWork,
                rollbackState: rollbackState
            )
            return try await TransactionScope.$current.withValue(frame) {
                let value = try await operation(unitOfWork)
                if await rollbackState.isRollbackOnly {
                    throw TransactionManagerError.rollbackOnly(transactionID)
                }
                try Task.checkCancellation()
                return value
            }
        }
    }
}

private struct TransactionFrame: Sendable {
    let managerID: UUID
    let transactionID: UUID
    let unitOfWork: any Sendable
    let rollbackState: TransactionRollbackState
}

private enum TransactionScope {
    @TaskLocal static var current: TransactionFrame?
}

private actor TransactionRollbackState {
    private(set) var isRollbackOnly = false

    func markRollbackOnly() {
        isRollbackOnly = true
    }
}

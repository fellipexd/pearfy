import Foundation
import Logging
import PearfyContext
import PearfyData
import PearfyObservability
import PearfyTransactions
import PostgresNIO

public actor PearfyPostgresDatabase: ApplicationLifecycle, SQLDatabase, PearfyTransactionalStore {
    public nonisolated let name = "Pearfy PostgreSQL"
    public typealias UnitOfWork = any SQLTransaction

    private let client: PostgresClient
    private let logger: Logger
    private let metrics: MetricsRegistry?
    private var clientTask: Task<Void, Never>?

    public init(
        configuration: PostgresClient.Configuration,
        logger: Logger = Logger(label: "Pearfy.Postgres"),
        metrics: MetricsRegistry? = nil
    ) {
        client = PostgresClient(configuration: configuration, backgroundLogger: logger)
        self.logger = logger
        self.metrics = metrics
    }

    /// Starts the pooled client and verifies connectivity before startup succeeds.
    public func start() async throws {
        guard clientTask == nil else { return }
        let client = self.client
        let task = Task { await client.run() }
        clientTask = task
        // Let PostgresClient.run() set its internal running state before the
        // startup connectivity probe attempts to lease a pool connection.
        await Task.yield()
        do {
            _ = try await client.query("SELECT 1", logger: logger).collect()
        } catch {
            task.cancel()
            await task.value
            clientTask = nil
            throw error
        }
    }

    public func stop() async throws {
        guard let task = clientTask else { return }
        clientTask = nil
        task.cancel()
        await task.value
    }

    public func execute(_ query: SQLQuery) async throws {
        try ensureStarted()
        try await perform("execute") {
            _ = try await client.query(try postgresQuery(query), logger: logger).collect()
        }
    }

    public func query<Row: PostgresDecodable & Sendable>(_ query: SQLQuery, as type: Row.Type = Row.self) async throws -> [Row] {
        try ensureStarted()
        return try await perform("query") {
            let rows = try await client.query(try postgresQuery(query), logger: logger)
            var decoded: [Row] = []
            for try await row in rows.decode(type) { decoded.append(row) }
            return decoded
        }
    }

    public func queryStrings(_ query: SQLQuery, column: String) async throws -> [String] {
        try ensureStarted()
        return try await perform("query") {
            let rows = try await client.query(try postgresQuery(query), logger: logger)
            var values: [String] = []
            for try await row in rows {
                guard let cell = row.first(where: { $0.columnName == column }) else {
                    throw SQLQueryError.missingColumn(column)
                }
                values.append(try cell.decode(String.self))
            }
            return values
        }
    }

    public func withTransaction<Value: Sendable>(
        _ operation: @Sendable (any SQLTransaction) async throws -> Value
    ) async throws -> Value {
        try await withTransaction(transactionID: UUID(), operation)
    }

    public func withTransaction<Value: Sendable>(
        transactionID: UUID,
        _ operation: @Sendable (any SQLTransaction) async throws -> Value
    ) async throws -> Value {
        try ensureStarted()
        do {
            return try await perform("transaction") {
                try await client.withTransaction(logger: logger) { connection in
                    try await operation(PostgresTransaction(connection: connection, logger: logger))
                }
            }
        } catch let error as PostgresTransactionError {
            throw classifiedTransactionError(error, transactionID: transactionID)
        }
    }

    public func withMigrationLock<Value: Sendable>(
        key: String,
        _ operation: @Sendable (any SQLTransaction) async throws -> Value
    ) async throws -> Value {
        try ensureStarted()
        let transactionID = UUID()
        do {
            return try await perform("migration") {
                try await client.withTransaction(logger: logger) { connection in
                    let transaction = PostgresTransaction(connection: connection, logger: logger)
                    try await transaction.execute(SQLQuery(
                        unsafeSQL: "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                        parameters: [.text(key)]
                    ))
                    return try await operation(transaction)
                }
            }
        } catch let error as PostgresTransactionError {
            throw classifiedTransactionError(error, transactionID: transactionID)
        }
    }

    private func classifiedTransactionError(
        _ error: PostgresTransactionError,
        transactionID: UUID
    ) -> any Error {
        if let commitError = error.commitError {
            return TransactionCommitOutcomeUnknown(
                transactionID: transactionID,
                reason: String(describing: commitError)
            )
        }
        if let closureError = error.closureError {
            return error.rollbackError == nil ? closureError : error
        }
        if let beginError = error.beginError { return beginError }
        return error
    }

    private func perform<Value: Sendable>(
        _ operation: String,
        work: @Sendable () async throws -> Value
    ) async throws -> Value {
        guard let metrics, let labels = try? MetricLabels(["operation": operation]) else {
            return try await work()
        }
        let clock = ContinuousClock()
        let start = clock.now
        try? await metrics.adjustGauge("pearfy_db_operations_in_flight", by: 1, labels: labels)
        do {
            let value = try await work()
            await recordOperationMetrics(metrics, labels: labels, start: start, clock: clock, failed: false)
            return value
        } catch {
            await recordOperationMetrics(metrics, labels: labels, start: start, clock: clock, failed: true)
            throw error
        }
    }

    private func recordOperationMetrics(
        _ metrics: MetricsRegistry,
        labels: MetricLabels,
        start: ContinuousClock.Instant,
        clock: ContinuousClock,
        failed: Bool
    ) async {
        try? await metrics.adjustGauge("pearfy_db_operations_in_flight", by: -1, labels: labels)
        let duration = start.duration(to: clock.now).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1_000_000_000_000_000_000
        try? await metrics.observe("pearfy_db_operation_duration_seconds", value: seconds, labels: labels)
        if failed { try? await metrics.increment("pearfy_db_operation_errors_total", labels: labels) }
    }

    private func ensureStarted() throws {
        guard clientTask != nil else { throw PostgresDatabaseError.notStarted }
    }
}

private struct PostgresTransaction: SQLTransaction, Sendable {
    let connection: PostgresConnection
    let logger: Logger

    func execute(_ query: SQLQuery) async throws {
        _ = try await connection.query(try postgresQuery(query), logger: logger).collect()
    }

    func queryStrings(_ query: SQLQuery, column: String) async throws -> [String] {
        let rows = try await connection.query(try postgresQuery(query), logger: logger)
        var values: [String] = []
        for try await row in rows {
            guard let cell = row.first(where: { $0.columnName == column }) else {
                throw SQLQueryError.missingColumn(column)
            }
            values.append(try cell.decode(String.self))
        }
        return values
    }
}

private enum PostgresDatabaseError: Error, Sendable {
    case notStarted
}

private func postgresQuery(_ query: SQLQuery) throws -> PostgresQuery {
    var bindings = PostgresBindings(capacity: query.parameters.count)
    for parameter in query.parameters {
        switch parameter {
        case .null: bindings.appendNull()
        case .text(let value): bindings.append(value)
        case .integer(let value): bindings.append(value)
        case .decimal(let value): bindings.append(value)
        case .boolean(let value): bindings.append(value)
        case .uuid(let value): bindings.append(value)
        case .bytes(let value): try bindings.append(value)
        }
    }
    return PostgresQuery(unsafeSQL: query.statement, binds: bindings)
}

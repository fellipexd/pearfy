import Foundation
import PearfyData
import PearfyObservability
import PearfyPostgres
import PostgresNIO
import Testing

@Test func postgresAdapterExecutesParameterizedQueriesAndCleansTransactions() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PORT"] ?? "5432") ?? 5432
    let username = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_USER"] ?? "postgres"
    let databaseName = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_DATABASE"] ?? username
    let password = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PASSWORD"]
    let tableName = "pearfy_it_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let table = try SQLIdentifier(tableName)
    let idColumn = try SQLIdentifier("id")
    let nameColumn = try SQLIdentifier("name")

    var configuration = PostgresClient.Configuration(
        host: host,
        port: port,
        username: username,
        password: password,
        database: databaseName,
        tls: .disable
    )
    configuration.options.maximumConnections = 1
    configuration.options.minimumConnections = 0
        configuration.options.connectionIdleTimeout = .seconds(5)
        configuration.options.connectTimeout = .seconds(5)

    let metrics = MetricsRegistry()
    let database = PearfyPostgresDatabase(configuration: configuration, metrics: metrics)
    try await database.start()

    do {
        try await database.execute(SQLQuery(unsafeSQL: "CREATE TABLE \(table) (\(idColumn) TEXT PRIMARY KEY, \(nameColumn) TEXT NOT NULL)"))

        let insert = try SQLQuery.insert(into: table, values: [
            idColumn: .text("one"),
            nameColumn: .text("bound ' value")
        ])
        try await database.execute(insert)
        let select = try SQLQuery.select(
            [nameColumn],
            from: table,
            where: [SQLFilter(idColumn, .equal, .text("one"))]
        )
        #expect(try await database.queryStrings(select, column: "name") == ["bound ' value"])

        let committedID = "commit-" + UUID().uuidString
        let committedInsert = try SQLQuery.insert(into: table, values: [
            idColumn: .text(committedID),
            nameColumn: .text("committed")
        ])
        _ = try await database.withTransaction { transaction in
            try await transaction.execute(committedInsert)
            return true
        }
        let committedQuery = try SQLQuery.select(
            [idColumn],
            from: table,
            where: [SQLFilter(idColumn, .equal, .text(committedID))]
        )
        #expect(try await database.queryStrings(committedQuery, column: "id") == [committedID])

        let failedID = "error-" + UUID().uuidString
        let failedInsert = try SQLQuery.insert(into: table, values: [
            idColumn: .text(failedID),
            nameColumn: .text("must rollback after error")
        ])
        var transactionErrorObserved = false
        do {
            _ = try await database.withTransaction { transaction in
                try await transaction.execute(failedInsert)
                throw PostgresIntegrationFailure.abort
            }
        } catch {
            transactionErrorObserved = true
        }
        #expect(transactionErrorObserved)
        let failedQuery = try SQLQuery.select(
            [idColumn],
            from: table,
            where: [SQLFilter(idColumn, .equal, .text(failedID))]
        )
        #expect(try await database.queryStrings(failedQuery, column: "id").isEmpty)

        let pooledResults = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let query = SQLQuery(
                        unsafeSQL: "SELECT $1::TEXT AS result, pg_sleep(0.01)",
                        parameters: [.text("request-\(index)")]
                    )
                    return try await database.queryStrings(query, column: "result").first ?? "missing"
                }
            }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(Set(pooledResults).count == 12)

        let rollbackID = "rollback-" + UUID().uuidString
        let rollbackInsert = try SQLQuery.insert(into: table, values: [
            idColumn: .text(rollbackID),
            nameColumn: .text("must rollback")
        ])
        let rollbackResult = Task {
            try await database.withTransaction { transaction in
                try await transaction.execute(rollbackInsert)
                try await Task.sleep(for: .seconds(30))
                return true
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        rollbackResult.cancel()
        if case .success = await rollbackResult.result {
            Issue.record("Cancelled PostgreSQL transaction unexpectedly committed")
        }

        let rolledBack = try SQLQuery.select(
            [idColumn],
            from: table,
            where: [SQLFilter(idColumn, .equal, .text(rollbackID))]
        )
        #expect(try await database.queryStrings(rolledBack, column: "id").isEmpty)
        // Reusing the single-connection pool confirms the cancelled transaction returned its lease.
        #expect(try await database.queryStrings(select, column: "name") == ["bound ' value"])
        let databaseMetrics = await metrics.prometheusText()
        #expect(databaseMetrics.contains("pearfy_db_operations_in_flight{operation=\"query\"} 0.0"))
        #expect(databaseMetrics.contains("pearfy_db_operation_duration_seconds_count"))
        try await database.execute(SQLQuery(unsafeSQL: "DROP TABLE \(table)"))
    } catch {
        try? await database.execute(SQLQuery(unsafeSQL: "DROP TABLE IF EXISTS \(table)"))
        try? await database.stop()
        throw error
    }

    try await database.stop()
}

private enum PostgresIntegrationFailure: Error, Sendable {
    case abort
}

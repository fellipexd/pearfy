import Foundation
import PearfyData
import PearfyObservability
import PearfyPostgres
import PearfyTransactions
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
    let schemaTableName = "pearfy_schema_it_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let schemaTable = try SQLIdentifier(schemaTableName)
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
        let baseSchema = try SchemaIR(entities: [SchemaEntity(
            table: schemaTableName,
            columns: [
                SchemaColumn(name: "id", type: .uuid, primaryKey: true, identifierStrategy: .uuidV7),
                SchemaColumn(name: "email", type: .text, nullable: true)
            ],
            indexes: [SchemaIndex(name: "\(schemaTableName)_email_idx", columns: ["email"], unique: true)]
        )])
        let schemaCompiler = PostgresSchemaCompiler()
        let createSchemaPlan = try schemaCompiler.plan(from: nil, to: baseSchema)
        for statement in createSchemaPlan.upStatements {
            try await database.execute(SQLQuery(unsafeSQL: statement))
        }
        let expandedSchema = try SchemaIR(entities: [SchemaEntity(
            table: schemaTableName,
            columns: [
                SchemaColumn(name: "id", type: .uuid, primaryKey: true, identifierStrategy: .uuidV7),
                SchemaColumn(name: "email", type: .text, nullable: true),
                SchemaColumn(name: "active", type: .boolean, nullable: true)
            ],
            indexes: [SchemaIndex(name: "\(schemaTableName)_email_idx", columns: ["email"], unique: true)]
        )])
        let additiveSchemaPlan = try schemaCompiler.plan(from: baseSchema, to: expandedSchema)
        #expect(additiveSchemaPlan.upStatements == ["ALTER TABLE \"\(schemaTableName)\" ADD COLUMN \"active\" BOOLEAN NULL"])
        for statement in additiveSchemaPlan.upStatements {
            try await database.execute(SQLQuery(unsafeSQL: statement))
        }
        let schemaColumns = try await database.queryStrings(
            SQLQuery(
                unsafeSQL: "SELECT column_name::TEXT AS column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1 ORDER BY column_name",
                parameters: [.text(schemaTableName)]
            ),
            column: "column_name"
        )
        #expect(schemaColumns == ["active", "email", "id"])

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
        try await database.execute(SQLQuery(unsafeSQL: "DROP TABLE \(schemaTable)"))
    } catch {
        try? await database.execute(SQLQuery(unsafeSQL: "DROP TABLE IF EXISTS \(table)"))
        try? await database.execute(SQLQuery(unsafeSQL: "DROP TABLE IF EXISTS \(schemaTable)"))
        try? await database.stop()
        throw error
    }

    try await database.stop()
}

@Test func postgresMigrationRunnerSerializesConcurrentApplyAndRejectsDrift() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PORT"] ?? "5432") ?? 5432
    let username = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_USER"] ?? "postgres"
    let databaseName = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_DATABASE"] ?? username
    let password = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PASSWORD"]
    let suffix = UUIDv7.generate().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let tableName = "pearfy_migration_it_\(suffix)"
    let journalName = "pearfy_migration_journal_it_\(suffix)"
    let table = try SQLIdentifier(tableName)
    let journal = try SQLIdentifier(journalName)
    let migration = SQLMigration(
        id: "it-\(suffix)",
        up: SQLQuery(unsafeSQL: "CREATE TABLE \(table) (id UUID PRIMARY KEY)"),
        down: SQLQuery(unsafeSQL: "DROP TABLE \(table)")
    )
    let changedMigration = SQLMigration(
        id: migration.id,
        up: SQLQuery(unsafeSQL: "CREATE TABLE \(table) (id TEXT PRIMARY KEY)"),
        down: migration.down
    )

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

    let firstDatabase = PearfyPostgresDatabase(configuration: configuration)
    let secondDatabase = PearfyPostgresDatabase(configuration: configuration)
    let runner = SQLMigrationRunner(journalTable: journal)
    do {
        try await firstDatabase.start()
        try await secondDatabase.start()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await runner.apply([migration], to: firstDatabase) }
            group.addTask { try await runner.apply([migration], to: secondDatabase) }
            try await group.waitForAll()
        }

        let journalChecksums = try await firstDatabase.queryStrings(SQLQuery(
            unsafeSQL: "SELECT checksum FROM \(journal) WHERE id = $1",
            parameters: [.text(migration.id)]
        ), column: "checksum")
        #expect(journalChecksums == [migration.checksum])

        var checksumDriftRejected = false
        do {
            try await runner.apply([changedMigration], to: secondDatabase)
        } catch SQLQueryError.migrationChecksumMismatch(let id, _, _) {
            checksumDriftRejected = id == migration.id
        }
        #expect(checksumDriftRejected)

        let failingMigration = SQLMigration(
            id: "zz-failed-\(suffix)",
            up: SQLQuery(unsafeSQL: "CREATE TABLE \(table) (duplicate_id UUID PRIMARY KEY)")
        )
        var failedMigrationRolledBack = false
        do {
            try await runner.apply([failingMigration], to: secondDatabase)
        } catch {
            failedMigrationRolledBack = true
        }
        #expect(failedMigrationRolledBack)
        #expect(try await secondDatabase.queryStrings(SQLQuery(
            unsafeSQL: "SELECT checksum FROM \(journal) WHERE id = $1",
            parameters: [.text(failingMigration.id)]
        ), column: "checksum").isEmpty)

        try await runner.rollback(migration, on: firstDatabase)
        #expect(try await firstDatabase.queryStrings(SQLQuery(
            unsafeSQL: "SELECT checksum FROM \(journal) WHERE id = $1",
            parameters: [.text(migration.id)]
        ), column: "checksum").isEmpty)
        try await firstDatabase.execute(SQLQuery(unsafeSQL: "DROP TABLE \(journal)"))
    } catch {
        try? await firstDatabase.execute(SQLQuery(unsafeSQL: "DROP TABLE IF EXISTS \(table)"))
        try? await firstDatabase.execute(SQLQuery(unsafeSQL: "DROP TABLE IF EXISTS \(journal)"))
        try? await firstDatabase.stop()
        try? await secondDatabase.stop()
        throw error
    }

    try await firstDatabase.stop()
    try await secondDatabase.stop()
}

@Test func postgresTransactionManagerCommitsAndRollsBackOnOnePhysicalTransaction() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PORT"] ?? "5432") ?? 5432
    let username = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_USER"] ?? "postgres"
    let databaseName = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_DATABASE"] ?? username
    let password = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PASSWORD"]
    let table = try SQLIdentifier("pearfy_transaction_manager_it_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
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

    let database = PearfyPostgresDatabase(configuration: configuration)
    let manager = PearfyTransactionManager(store: database)
    try await database.start()
    do {
        try await database.execute(SQLQuery(unsafeSQL: "CREATE TABLE \(table) (id UUID PRIMARY KEY)"))

        let committedID = UUIDv7.generate()
        try await manager.withTransaction { transaction in
            try await transaction.execute(SQLQuery(
                unsafeSQL: "INSERT INTO \(table) (id) VALUES ($1)",
                parameters: [.uuid(committedID)]
            ))
        }
        let committedRows = try await database.queryStrings(SQLQuery(
            unsafeSQL: "SELECT id::TEXT AS id FROM \(table) WHERE id = $1",
            parameters: [.uuid(committedID)]
        ), column: "id")
        #expect(committedRows == [committedID.uuidString.lowercased()])

        let rolledBackID = UUIDv7.generate()
        var originalErrorPropagated = false
        do {
            try await manager.withTransaction { transaction in
                try await transaction.execute(SQLQuery(
                    unsafeSQL: "INSERT INTO \(table) (id) VALUES ($1)",
                    parameters: [.uuid(rolledBackID)]
                ))
                throw PostgresIntegrationFailure.abort
            }
        } catch PostgresIntegrationFailure.abort {
            originalErrorPropagated = true
        }
        #expect(originalErrorPropagated)
        #expect(try await database.queryStrings(SQLQuery(
            unsafeSQL: "SELECT id::TEXT AS id FROM \(table) WHERE id = $1",
            parameters: [.uuid(rolledBackID)]
        ), column: "id").isEmpty)

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

import Foundation
import PearfyData
import PearfyPostgres
import PearfyPopulateCore
import PearfyPopulatePostgres
import Testing

@Test func postgresPopulateIntrospectionReadsLiveCatalogWhenConfigured() async throws {
    guard ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_HOST"] != nil else { return }
    try await withPopulatePostgresTestDatabase { database in
        try await withPopulateTestSchema(database, prefix: "pearfy_introspection") { schema, quotedSchema in
            try await database.execute(SQLQuery(unsafeSQL: "CREATE TABLE \(quotedSchema).items (id INTEGER PRIMARY KEY)"))
            let snapshot = try await PearfyPostgresPopulateAdapter.inspect(database: database)
            #expect(!snapshot.databaseName.isEmpty)
            #expect(snapshot.tables.contains { $0.schema == schema && $0.name == "items" })
            #expect(snapshot.tables.allSatisfy { !$0.schema.isEmpty && !$0.name.isEmpty })
            #expect(try snapshot.fingerprint().count == 64)
        }
    }
}

@Test func postgresPopulateExecutesChecksAndResumesACommittedBatchWhenConfigured() async throws {
    guard ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_HOST"] != nil else { return }
    try await withPopulatePostgresTestDatabase { database in
        try await withPopulateTestSchema(database, prefix: "pearfy_populate_test") { schema, quotedSchema in
            try await database.execute(SQLQuery(unsafeSQL: """
                CREATE TABLE \(quotedSchema).\"items\" (
                    \"id\" UUID PRIMARY KEY,
                    \"slug\" VARCHAR(96) NOT NULL UNIQUE,
                    \"score\" INTEGER NOT NULL CHECK (\"score\" >= 0)
                )
                """))
            let snapshot = try await PearfyPostgresPopulateAdapter.inspect(database: database)
            let table = try snapshot.table(named: "\(schema).items")
            let limits = try PopulateExecutionLimits(maxRows: 10, maxBatchRows: 2, maxRetries: 0, minimumFreeDiskBytes: 0)
            let metrics = try await PearfyPostgresPopulateAdapter(database: database, snapshot: snapshot).size(of: table)
            let plan = try PopulatePlanner.makePlan(
                request: PopulatePlanRequest(table: table.qualifiedName, environment: .local, seed: 91, requestedRows: 5, limits: limits),
                snapshot: snapshot,
                currentRowCount: metrics.rowCount,
                currentSizeBytes: metrics.totalBytes
            )
            let adapter = PearfyPostgresPopulateAdapter(database: database, snapshot: snapshot)
            let runDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("pearfy-populate-runs-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: runDirectory) }
            let registry = FilePopulateRunRegistry(directory: runDirectory)
            let runner = PopulateRunner()

            let partial = try await runner.execute(
                plan: plan,
                approvalHash: plan.planHash,
                currentSchemaFingerprint: plan.schemaFingerprint,
                store: adapter,
                registry: registry,
                batchLimit: 1
            )
            #expect(partial.status == .partial)
            #expect(partial.processedRows == 2)

            let complete = try await runner.execute(
                plan: plan,
                approvalHash: plan.planHash,
                currentSchemaFingerprint: plan.schemaFingerprint,
                store: adapter,
                registry: registry
            )
            #expect(complete.status == .complete)
            #expect(complete.insertedRows == 5)
            #expect(try await adapter.verify(plan).rowCount == 5)
        }
    }
}

private func withPopulatePostgresTestDatabase<T>(
    _ operation: (PearfyPostgresDatabase) async throws -> T
) async throws -> T {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_HOST"] else {
        throw PopulatePostgresIntegrationSetupError.missingHost
    }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PORT"] ?? "5432") ?? 5432
    let username = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_USER"] ?? "postgres"
    let password = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PASSWORD"]
    let databaseName = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_DATABASE"] ?? "postgres"
    let settings = try PearfyPostgresConnectionSettings(
        host: host,
        port: port,
        username: username,
        password: password,
        database: databaseName,
        tls: .disabled,
        maximumConnections: 1
    )
    let database = PearfyPostgresDatabase(settings: settings)
    try await database.start()
    do {
        let result = try await operation(database)
        try await database.stop()
        return result
    } catch {
        try? await database.stop()
        throw error
    }
}

private enum PopulatePostgresIntegrationSetupError: Error {
    case missingHost
}

private func withPopulateTestSchema<T>(
    _ database: PearfyPostgresDatabase,
    prefix: String,
    operation: (String, String) async throws -> T
) async throws -> T {
    let schema = "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    let quotedSchema = try SQLIdentifier(schema).description
    let cleanup = SQLQuery(unsafeSQL: "DROP SCHEMA IF EXISTS \(quotedSchema) CASCADE")
    try await database.execute(SQLQuery(unsafeSQL: "CREATE SCHEMA \(quotedSchema)"))
    do {
        let result = try await operation(schema, quotedSchema)
        try await database.execute(cleanup)
        return result
    } catch {
        try? await database.execute(cleanup)
        throw error
    }
}

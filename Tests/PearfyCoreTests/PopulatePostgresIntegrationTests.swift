import Foundation
import PearfyData
import PearfyPostgres
import PearfyPopulateCore
import PearfyPopulatePostgres
import Testing

@Test func postgresPopulateIntrospectionReadsLiveCatalogWhenConfigured() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_HOST"] else { return }
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
        maximumConnections: 2
    )
    let database = PearfyPostgresDatabase(settings: settings)
    try await database.start()
    defer { Task { try? await database.stop() } }

    let snapshot = try await PearfyPostgresPopulateAdapter.inspect(database: database)
    #expect(!snapshot.databaseName.isEmpty)
    #expect(snapshot.tables.allSatisfy { !$0.schema.isEmpty && !$0.name.isEmpty })
    #expect(try snapshot.fingerprint().count == 64)
}

@Test func postgresPopulateExecutesChecksAndResumesACommittedBatchWhenConfigured() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_HOST"] else { return }
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
        maximumConnections: 4
    )
    let database = PearfyPostgresDatabase(settings: settings)
    try await database.start()
    let schema = "pearfy_populate_test_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    let quotedSchema = try SQLIdentifier(schema).description
    let cleanup = SQLQuery(unsafeSQL: "DROP SCHEMA IF EXISTS \(quotedSchema) CASCADE")
    var cleanupOnExit = true
    defer {
        if cleanupOnExit {
            Task {
                try? await database.execute(cleanup)
                try? await database.stop()
            }
        }
    }

    try await database.execute(SQLQuery(unsafeSQL: "CREATE SCHEMA \(quotedSchema)"))
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

    try await database.execute(cleanup)
    try await database.stop()
    cleanupOnExit = false
}

import Foundation
import PearfyData
import Testing

@Test func sqlBuildersQuoteIdentifiersAndKeepValuesInBindings() throws {
    let table = try SQLIdentifier("users")
    let email = try SQLIdentifier("email")
    let query = try SQLQuery.select(
        [try SQLIdentifier("id"), email],
        from: table,
        where: [SQLFilter(email, .equal, .text("' OR 1=1 --"))],
        limit: 25
    )

    #expect(query.statement == "SELECT \"id\", \"email\" FROM \"users\" WHERE \"email\" = $1 LIMIT $2")
    #expect(query.parameters == [.text("' OR 1=1 --"), .integer(25)])
}

@Test func sqlBuildersRefuseUnboundedMutationsAndUnsafeIdentifiers() throws {
    var invalidIdentifierRejected = false
    do {
        _ = try SQLIdentifier("users; DROP TABLE users")
    } catch SQLQueryError.invalidIdentifier {
        invalidIdentifierRejected = true
    }
    #expect(invalidIdentifierRejected)

    var unboundedUpdateRejected = false
    do {
        _ = try SQLQuery.update(try SQLIdentifier("users"), values: [try SQLIdentifier("name"): .text("x")], where: [])
    } catch SQLQueryError.emptyMutation {
        unboundedUpdateRejected = true
    }
    #expect(unboundedUpdateRejected)
}

@Test func uuidV7EncodesUnixMillisecondsVersionAndRFCVariant() {
    let beforeMilliseconds = UInt64(Date().timeIntervalSince1970 * 1_000)
    let identifier = UUIDv7.generate()
    let afterMilliseconds = UInt64(Date().timeIntervalSince1970 * 1_000)
    let bytes = identifier.uuid

    #expect(bytes.6 >> 4 == 7)
    #expect(bytes.8 >> 6 == 2)
    let timestamp = UUIDv7.timestampMilliseconds(from: identifier)
    #expect(timestamp != nil)
    if let timestamp {
        #expect(timestamp >= beforeMilliseconds)
        #expect(timestamp <= afterMilliseconds)
    }
}

@Test func migrationRunnerAppliesEachVersionOnceInsideTransactions() async throws {
    let store = MigrationStore()
    let database = FakeDatabase(store: store)
    let runner = SQLMigrationRunner()
    let migrations = [
        SQLMigration(id: "002-users", up: SQLQuery(unsafeSQL: "CREATE TABLE users (id BIGINT)")),
        SQLMigration(id: "001-accounts", up: SQLQuery(unsafeSQL: "CREATE TABLE accounts (id BIGINT)"))
    ]

    try await runner.apply(migrations, to: database)
    try await runner.apply(migrations, to: database)

    let executed = await store.statements
    #expect(await store.appliedIDs == ["001-accounts", "002-users"])
    #expect(executed.filter { $0 == "CREATE TABLE users (id BIGINT)" }.count == 1)
    #expect(executed.filter { $0 == "CREATE TABLE accounts (id BIGINT)" }.count == 1)
}

@Test func migrationRunnerDetectsChecksumDriftAndAdoptsLegacyJournalRows() async throws {
    let store = MigrationStore()
    let database = FakeDatabase(store: store)
    let runner = SQLMigrationRunner()
    let migration = SQLMigration(
        id: "003-profile-index",
        up: SQLQuery(unsafeSQL: "CREATE INDEX profiles_email_idx ON profiles (email)"),
        down: SQLQuery(unsafeSQL: "DROP INDEX profiles_email_idx")
    )

    #expect(migration.checksum == migration.checksum)
    try await runner.apply([migration], to: database)

    let changedMigration = SQLMigration(
        id: migration.id,
        up: SQLQuery(unsafeSQL: "CREATE INDEX profiles_email_idx ON profiles (email, id)"),
        down: migration.down
    )
    var checksumDriftRejected = false
    do {
        try await runner.apply([changedMigration], to: database)
    } catch SQLQueryError.migrationChecksumMismatch(let id, _, _) {
        checksumDriftRejected = id == migration.id
    }
    #expect(checksumDriftRejected)

    let legacyStore = MigrationStore()
    await legacyStore.seedLegacy(id: migration.id)
    let legacyDatabase = FakeDatabase(store: legacyStore)
    try await runner.apply([migration], to: legacyDatabase)
    #expect(await legacyStore.recordedChecksum(id: migration.id) == migration.checksum)
    #expect(await legacyStore.statements.filter { $0 == migration.up.statement }.isEmpty)
}

@Test func migrationRunnerPlanReportsPendingAppliedLegacyAndDrift() async throws {
    let store = MigrationStore()
    let database = FakeDatabase(store: store)
    let runner = SQLMigrationRunner()
    let first = SQLMigration(id: "010-create-profiles", up: SQLQuery(unsafeSQL: "CREATE TABLE profiles (id UUID)"))
    let second = SQLMigration(id: "020-add-profile-name", up: SQLQuery(unsafeSQL: "ALTER TABLE profiles ADD name TEXT"))

    let initialPlan = try await runner.plan([second, first], on: database)
    #expect(initialPlan.entries.map(\.id) == [first.id, second.id])
    #expect(initialPlan.pendingIDs == [first.id, second.id])
    #expect(!initialPlan.isUpToDate)

    try await runner.apply([first], to: database)
    let partialPlan = try await runner.plan([first, second], on: database)
    #expect(partialPlan.entries.map(\.status) == [.applied, .pending])
    #expect(partialPlan.pendingIDs == [second.id])

    let changedFirst = SQLMigration(id: first.id, up: SQLQuery(unsafeSQL: "CREATE TABLE profiles (id UUID, name TEXT)"))
    let driftPlan = try await runner.plan([changedFirst], on: database)
    #expect(driftPlan.driftedIDs == [first.id])

    let legacyStore = MigrationStore()
    await legacyStore.seedLegacy(id: first.id)
    let legacyDatabase = FakeDatabase(store: legacyStore)
    let legacyPlan = try await runner.plan([first], on: legacyDatabase)
    #expect(legacyPlan.legacyIDs == [first.id])
    #expect(await legacyStore.recordedChecksum(id: first.id) == nil)
}

@Test func migrationCatalogLoadsSortedParameterizedArtifactsAndValidatesFilenames() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-migrations-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let first = SQLMigrationArtifact(
        id: "001-insert-ledger-entry",
        up: SQLMigrationCommand(
            sql: "INSERT INTO ledger (name, payload) VALUES ($1, $2)",
            parameters: [.text("audit"), .bytes(Data([0x01, 0x02]))]
        ),
        down: SQLMigrationCommand(sql: "DELETE FROM ledger WHERE name = $1", parameters: [.text("audit")])
    )
    let second = SQLMigrationArtifact(
        id: "002-add-index",
        up: SQLMigrationCommand(sql: "CREATE INDEX ledger_name_idx ON ledger (name)")
    )
    try first.canonicalJSON().write(to: directory.appendingPathComponent("001-insert-ledger-entry.json"), options: .atomic)
    try second.canonicalJSON().write(to: directory.appendingPathComponent("002-add-index.json"), options: .atomic)

    let catalog = try SQLMigrationCatalog(directory: directory)
    #expect(catalog.migrations.map(\.id) == [first.id, second.id])
    #expect(catalog.migrations[0].up.parameters == [.text("audit"), .bytes(Data([0x01, 0x02]))])
    #expect(catalog.migrations[0].checksum == first.migration.checksum)

    let mismatch = SQLMigrationArtifact(
        id: "003-wrong-name",
        up: SQLMigrationCommand(sql: "SELECT 1")
    )
    try mismatch.canonicalJSON().write(to: directory.appendingPathComponent("different-id.json"), options: .atomic)
    var filenameMismatchRejected = false
    do {
        _ = try SQLMigrationCatalog(directory: directory)
    } catch SQLMigrationCatalogError.filenameDoesNotMatch(_, let id) {
        filenameMismatchRejected = id == mismatch.id
    }
    #expect(filenameMismatchRejected)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("different-id.json"))

    let emptySQLArtifact = SQLMigrationArtifact(
        id: "004-empty-sql",
        up: SQLMigrationCommand(sql: "  \n")
    )
    try emptySQLArtifact.canonicalJSON().write(to: directory.appendingPathComponent("004-empty-sql.json"), options: .atomic)
    var emptySQLRejected = false
    do {
        _ = try SQLMigrationCatalog(directory: directory)
    } catch SQLMigrationCatalogError.invalidArtifact(_, let reason) {
        emptySQLRejected = reason.contains("non-empty")
    }
    #expect(emptySQLRejected)
}

@Test func migrationRunnerRejectsInvalidAndDuplicateIDsBeforeDatabaseWork() async throws {
    let store = MigrationStore()
    let database = FakeDatabase(store: store)
    let runner = SQLMigrationRunner()
    let valid = SQLMigration(id: "001-valid", up: SQLQuery(unsafeSQL: "SELECT 1"))

    var duplicateRejected = false
    do {
        try await runner.apply([valid, valid], to: database)
    } catch SQLQueryError.duplicateMigration("001-valid") {
        duplicateRejected = true
    }
    #expect(duplicateRejected)
    #expect(await store.statements.isEmpty)

    let invalid = SQLMigration(id: "Invalid ID", up: SQLQuery(unsafeSQL: "SELECT 1"))
    var invalidIDRejected = false
    do {
        try await runner.apply([invalid], to: database)
    } catch SQLQueryError.invalidMigrationID("Invalid ID") {
        invalidIDRejected = true
    }
    #expect(invalidIDRejected)
    #expect(await store.statements.isEmpty)
}

private actor MigrationStore {
    private struct Record: Sendable {
        var checksum: String?
    }

    private var records: [String: Record] = [:]
    private(set) var statements: [String] = []

    var appliedIDs: Set<String> { Set(records.keys) }

    func execute(_ query: SQLQuery) {
        statements.append(query.statement)
        if query.statement.hasPrefix("INSERT INTO \"pearfy_schema_migrations\"") {
            if case .text(let id)? = query.parameters.first,
               case .text(let checksum)? = query.parameters.dropFirst().first {
                records[id] = Record(checksum: checksum)
            }
        } else if query.statement.hasPrefix("UPDATE \"pearfy_schema_migrations\" SET checksum") {
            if case .text(let id)? = query.parameters.first,
               case .text(let checksum)? = query.parameters.dropFirst().first,
               records[id] != nil {
                records[id] = Record(checksum: checksum)
            }
        } else if query.statement.hasPrefix("DELETE FROM \"pearfy_schema_migrations\"") {
            if case .text(let id)? = query.parameters.first { records.removeValue(forKey: id) }
        }
    }

    func queryStrings(_ query: SQLQuery) -> [String] {
        guard case .text(let id)? = query.parameters.first,
              let record = records[id] else { return [] }
        return [record.checksum ?? "<legacy-null>"]
    }

    func seedLegacy(id: String) {
        records[id] = Record(checksum: nil)
    }

    func recordedChecksum(id: String) -> String? { records[id]?.checksum }
}

private struct FakeDatabase: SQLDatabase {
    let store: MigrationStore

    func execute(_ query: SQLQuery) async throws {
        await store.execute(query)
    }

    func queryStrings(_ query: SQLQuery, column: String) async throws -> [String] {
        await store.queryStrings(query)
    }

    func withTransaction<Value: Sendable>(
        _ operation: @Sendable (any SQLTransaction) async throws -> Value
    ) async throws -> Value {
        try await operation(FakeTransaction(store: store))
    }

    func withMigrationLock<Value: Sendable>(
        key: String,
        _ operation: @Sendable (any SQLTransaction) async throws -> Value
    ) async throws -> Value {
        try await operation(FakeTransaction(store: store))
    }
}

private struct FakeTransaction: SQLTransaction {
    let store: MigrationStore

    func execute(_ query: SQLQuery) async throws {
        await store.execute(query)
    }

    func queryStrings(_ query: SQLQuery, column: String) async throws -> [String] {
        await store.queryStrings(query)
    }
}

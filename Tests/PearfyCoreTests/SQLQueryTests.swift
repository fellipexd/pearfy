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

private actor MigrationStore {
    private(set) var appliedIDs: Set<String> = []
    private(set) var statements: [String] = []

    func execute(_ query: SQLQuery) {
        statements.append(query.statement)
        if query.statement.hasPrefix("INSERT INTO \"pearfy_schema_migrations\"") {
            if case .text(let id)? = query.parameters.first { appliedIDs.insert(id) }
        } else if query.statement.hasPrefix("DELETE FROM \"pearfy_schema_migrations\"") {
            if case .text(let id)? = query.parameters.first { appliedIDs.remove(id) }
        }
    }

    func queryStrings() -> [String] { appliedIDs.sorted() }
}

private struct FakeDatabase: SQLDatabase {
    let store: MigrationStore

    func execute(_ query: SQLQuery) async throws {
        await store.execute(query)
    }

    func queryStrings(_ query: SQLQuery, column: String) async throws -> [String] {
        await store.queryStrings()
    }

    func withTransaction<Value: Sendable>(
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
        await store.queryStrings()
    }
}

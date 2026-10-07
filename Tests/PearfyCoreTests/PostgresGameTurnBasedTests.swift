import Foundation
import PearfyData
import PearfyGameServer
import PearfyGameServerTurnBased
import PearfyGameServerTurnBasedPostgres
import PearfyPostgres
import PostgresNIO
import Testing

private actor TurnBasedSQLRecorder: SQLDatabase {
    private var recorded: [SQLQuery] = []
    private var transactionCount = 0

    func execute(_ query: SQLQuery) async throws { recorded.append(query) }
    func queryStrings(_ query: SQLQuery, column: String) async throws -> [String] { recorded.append(query); return [] }
    func withTransaction<Value: Sendable>(_ operation: @Sendable (any SQLTransaction) async throws -> Value) async throws -> Value {
        transactionCount += 1
        return try await operation(TurnBasedSQLTransaction(recorder: self))
    }
    func withMigrationLock<Value: Sendable>(key: String, _ operation: @Sendable (any SQLTransaction) async throws -> Value) async throws -> Value {
        try await withTransaction(operation)
    }
    func record(_ query: SQLQuery) { recorded.append(query) }
    func snapshot() -> (queries: [SQLQuery], transactions: Int) { (recorded, transactionCount) }
}

private struct TurnBasedSQLTransaction: SQLTransaction {
    let recorder: TurnBasedSQLRecorder
    func execute(_ query: SQLQuery) async throws { await recorder.record(query) }
    func queryStrings(_ query: SQLQuery, column: String) async throws -> [String] {
        await recorder.record(query)
        return []
    }
}

@Test func postgresTurnBasedMigrationAndAppendAreBoundedAndTransactional() async throws {
    let recorder = TurnBasedSQLRecorder()
    let prefix = "game_turn_unit"
    let migration = try PostgresGameTurnBasedCommandStore.migration(tablePrefix: prefix)
    let store = try PostgresGameTurnBasedCommandStore(database: recorder, tablePrefix: prefix)
    let event = GameStateEvent(sequence: 1, commandID: UUID(), playerID: UUID(), payload: Data([1, 2]), state: Data([3, 4]))

    let result = try await store.append(sessionID: UUID(), expectedRevision: 0, event: event)
    let recorded = await recorder.snapshot()
    #expect(migration.id == "pearfy-game-turn-based-v1-game_turn_unit")
    #expect(migration.up.statement.contains("UNIQUE (session_id, command_id)"))
    #expect(result == .appended(event))
    #expect(recorded.transactions == 1)
    #expect(recorded.queries.contains { $0.statement.contains("pg_advisory_xact_lock") })
    #expect(recorded.queries.contains { $0.statement.contains("INSERT INTO \"game_turn_unit_events\"") })
    #expect(recorded.queries.contains { $0.statement.contains("INSERT INTO \"game_turn_unit_sessions\"") })
    #expect(recorded.queries.contains { $0.parameters.contains(.uuid(event.commandID)) })
    #expect(recorded.queries.contains { $0.parameters.contains(.bytes(event.payload)) })
}

@Test func postgresTurnBasedRejectsUnsafeIdentifiersAndInvalidBounds() throws {
    let database = TurnBasedSQLRecorder()
    #expect(throws: SQLQueryError.self) {
        try PostgresGameTurnBasedCommandStore.migration(tablePrefix: "x;")
    }
    #expect(throws: PostgresGameTurnBasedError.self) {
        try PostgresGameTurnBasedConfiguration(maximumEvents: 0)
    }
    #expect(throws: PostgresGameTurnBasedError.self) {
        try PostgresGameTurnBasedCommandStore(database: database, tablePrefix: "this_prefix_is_far_too_long_for_safe_table_names")
    }
}

@Test func postgresTurnBasedSessionsSurviveReplicaReopenAndFenceStaleWriters() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PORT"] ?? "5432") ?? 5432
    let username = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_USER"] ?? "postgres"
    let databaseName = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_DATABASE"] ?? username
    let password = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PASSWORD"]
    let prefix = "pgtb" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20)
    let sessions = try SQLIdentifier("\(prefix)_sessions")
    let events = try SQLIdentifier("\(prefix)_events")
    var configuration = PostgresClient.Configuration(host: host, port: port, username: username, password: password, database: databaseName, tls: .disable)
    configuration.options.maximumConnections = 4
    configuration.options.minimumConnections = 0
    let database = PearfyPostgresDatabase(configuration: configuration)
    try await database.start()
    do {
        let migration = try PostgresGameTurnBasedCommandStore.migration(tablePrefix: String(prefix))
        try await database.withTransaction { transaction in try await transaction.executeMigrationScript(migration.up) }
        let firstStore = try PostgresGameTurnBasedCommandStore(database: database, tablePrefix: String(prefix))
        let sessionID = UUID()
        let playerID = UUID()
        let reducer: GameTurnBasedSession.Reducer = { state, _, command in
            guard let current = Int(String(decoding: state, as: UTF8.self)),
                  let delta = Int(String(decoding: command, as: UTF8.self)), delta > 0 else {
                throw TurnBasedSQLTestError.invalidCommand
            }
            return Data(String(current + delta).utf8)
        }
        let first = try await GameTurnBasedSession.open(sessionID: sessionID, initialState: Data("0".utf8), store: firstStore, reducer: reducer)
        let staleStore = try PostgresGameTurnBasedCommandStore(database: database, tablePrefix: String(prefix))
        let stale = try await GameTurnBasedSession.open(sessionID: sessionID, initialState: Data("0".utf8), store: staleStore, reducer: reducer)
        let commandID = UUID()
        _ = try await first.submit(commandID: commandID, playerID: playerID, command: Data("2".utf8))
        _ = try await first.submit(commandID: UUID(), playerID: playerID, command: Data("3".utf8))

        let secondStore = try PostgresGameTurnBasedCommandStore(database: database, tablePrefix: String(prefix))
        let restored = try await GameTurnBasedSession.open(sessionID: sessionID, initialState: Data("0".utf8), store: secondStore, reducer: reducer)
        #expect(await restored.currentRevision == 2)
        #expect(await restored.currentState() == Data("5".utf8))
        let duplicate = try await restored.submit(commandID: commandID, playerID: playerID, command: Data("2".utf8))
        if case .duplicate = duplicate { #expect(true) } else { Issue.record("the retry must return the original event") }
        do {
            _ = try await stale.submit(commandID: commandID, playerID: playerID, command: Data("2".utf8))
            Issue.record("a stale replica must not publish a duplicate event as the current state")
        } catch {
            #expect(error as? GameServerError == .revisionConflict(current: 2))
        }

        let thirdStore = try PostgresGameTurnBasedCommandStore(database: database, tablePrefix: String(prefix))
        let replicaA = try await GameTurnBasedSession.open(sessionID: sessionID, initialState: Data("0".utf8), store: thirdStore, reducer: reducer)
        let fourthStore = try PostgresGameTurnBasedCommandStore(database: database, tablePrefix: String(prefix))
        let replicaB = try await GameTurnBasedSession.open(sessionID: sessionID, initialState: Data("0".utf8), store: fourthStore, reducer: reducer)
        async let accepted = submitResult(replicaA, playerID: playerID, command: "3", expectedRevision: 2)
        async let rejected = submitResult(replicaB, playerID: playerID, command: "4", expectedRevision: 2)
        let outcomes = await [accepted, rejected]
        #expect(outcomes.filter { if case .success = $0 { true } else { false } }.count == 1)
        #expect(outcomes.filter { if case .failure = $0 { true } else { false } }.count == 1)
        let finalStore = try PostgresGameTurnBasedCommandStore(database: database, tablePrefix: String(prefix))
        #expect(try await finalStore.load(sessionID: sessionID)?.revision == 3)
        try await database.execute(SQLQuery(unsafeSQL: "DROP TABLE \(events), \(sessions) CASCADE"))
        try await database.stop()
    } catch {
        try? await database.execute(SQLQuery(unsafeSQL: "DROP TABLE IF EXISTS \(events), \(sessions) CASCADE"))
        try? await database.stop()
        throw error
    }
}

private enum TurnBasedSQLTestError: Error { case invalidCommand }

private func submitResult(_ session: GameTurnBasedSession, playerID: UUID, command: String, expectedRevision: UInt64) async -> Result<GameCommandResult, Error> {
    do {
        return .success(try await session.submit(commandID: UUID(), playerID: playerID, command: Data(command.utf8), expectedRevision: expectedRevision))
    } catch {
        return .failure(error)
    }
}

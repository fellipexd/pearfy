import Foundation
import PearfyData
import PearfyGameServer
import PearfyGameServerMatchmakingPostgres
import PearfyGameServerPostgres
import PearfyGameServerWorldPostgres
import PearfyPostgres
import PostgresNIO
import Testing

@Test func postgresGameWorldFencesZoneOwnersAndBoundsEntityTransfers() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PORT"] ?? "5432") ?? 5432
    let username = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_USER"] ?? "postgres"
    let databaseName = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_DATABASE"] ?? username
    let password = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PASSWORD"]
    let prefix = "pearfy_world_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20)
    let tables = try ["\(prefix)_zones", "\(prefix)_entities"].map { try SQLIdentifier($0).description }
    var postgres = PostgresClient.Configuration(host: host, port: port, username: username, password: password, database: databaseName, tls: .disable)
    postgres.options.maximumConnections = 4
    postgres.options.minimumConnections = 0
    let database = PearfyPostgresDatabase(configuration: postgres)
    try await database.start()
    defer {
        Task {
            for table in tables.reversed() { try? await database.execute(SQLQuery(unsafeSQL: "DROP TABLE IF EXISTS \(table) CASCADE")) }
            try? await database.stop()
        }
    }

    let configuration = try PostgresGameWorldConfiguration(maximumActiveZones: 2, maximumEntitiesPerZone: 2, maximumEntityStateBytes: 4, maximumStateBytesPerZone: 4)
    let migration = try PostgresGameWorldLeaseStore.migration(tablePrefix: prefix)
    try await database.withTransaction { transaction in try await transaction.executeMigrationScript(migration.up) }
    let firstReplica = try PostgresGameWorldLeaseStore(database: database, configuration: configuration, tablePrefix: prefix)
    let secondReplica = try PostgresGameWorldLeaseStore(database: database, configuration: configuration, tablePrefix: prefix)
    let sourceZone = UUID()
    let source = try await firstReplica.acquireLease(zoneID: sourceZone)
    #expect(source.fencingEpoch == 1)
    do {
        _ = try await secondReplica.acquireLease(zoneID: sourceZone)
        Issue.record("a running zone has one owner across replicas")
    } catch { #expect(error as? PostgresGameWorldError == .zoneLeaseHeld) }
    #expect(try await secondReplica.renewLease(source))

    let entity = try await firstReplica.createEntity(source, ownerID: UUID(), state: Data([1, 2]))
    _ = try await firstReplica.createEntity(source, state: Data([3, 4]))
    do {
        _ = try await firstReplica.createEntity(source, state: Data(repeating: 7, count: 5))
        Issue.record("per-entity byte budget is enforced")
    } catch { #expect(error as? PostgresGameWorldError == .entityStateTooLarge) }
    do {
        _ = try await firstReplica.createEntity(source, state: Data([5]))
        Issue.record("zone entity count and byte budgets are enforced")
    } catch { #expect(error as? PostgresGameWorldError == .entityCapacityReached) }
    let page = try await secondReplica.entities(in: source, limit: 1)
    #expect(page.total == 2)
    #expect(page.entities.count == 1)

    let destination = try await secondReplica.acquireLease(zoneID: UUID(), durationMilliseconds: 1_000)
    let moved = try await secondReplica.transferEntity(entityID: entity.id, from: source, to: destination)
    #expect(moved.zoneID == destination.zoneID)
    #expect(moved.fencingEpoch == entity.fencingEpoch + 1)
    do {
        _ = try await secondReplica.updateEntity(source, entityID: entity.id, expectedEntityEpoch: entity.fencingEpoch, state: Data([8]))
        Issue.record("the old zone cannot mutate an entity after handoff")
    } catch { #expect(error as? PostgresGameWorldError == .entityNotFound) }
    do {
        _ = try await secondReplica.updateEntity(destination, entityID: entity.id, expectedEntityEpoch: entity.fencingEpoch, state: Data([8]))
        Issue.record("the pre-transfer entity epoch is stale")
    } catch { #expect(error as? PostgresGameWorldError == .staleEntityEpoch) }
    let updated = try await secondReplica.updateEntity(destination, entityID: entity.id, expectedEntityEpoch: moved.fencingEpoch, state: Data([8, 9, 10]))
    #expect(updated.state == Data([8, 9, 10]))
    do {
        _ = try await secondReplica.createEntity(destination, state: Data([1, 2]))
        Issue.record("aggregate zone state bytes are bounded independently of entity count")
    } catch { #expect(error as? PostgresGameWorldError == .entityCapacityReached) }
    try await Task.sleep(for: .milliseconds(1_100))
    let destinationTakeover = try await firstReplica.acquireLease(zoneID: destination.zoneID)
    #expect(destinationTakeover.fencingEpoch == destination.fencingEpoch + 1)
    do {
        _ = try await secondReplica.updateEntity(destination, entityID: entity.id, expectedEntityEpoch: moved.fencingEpoch, state: Data([0]))
        Issue.record("an expired zone owner cannot mutate after takeover")
    } catch { #expect(error as? PostgresGameWorldError == .zoneLeaseExpired) }
    let recovered = try await firstReplica.entities(in: destinationTakeover)
    #expect(recovered.total == 1)
    #expect(recovered.entities.first?.state == Data([8, 9, 10]))

    let thirdZone = UUID()
    do {
        _ = try await firstReplica.acquireLease(zoneID: thirdZone)
        Issue.record("active zone count is bounded")
    } catch { #expect(error as? PostgresGameWorldError == .zoneCapacityReached) }
    let sourceEntities = try await firstReplica.entities(in: source, limit: 10)
    for remaining in sourceEntities.entities where remaining.id != entity.id {
        #expect(try await firstReplica.removeEntity(source, entityID: remaining.id, expectedEntityEpoch: remaining.fencingEpoch))
    }
    try await firstReplica.retireZone(source)
    do {
        _ = try await secondReplica.acquireLease(zoneID: sourceZone)
        Issue.record("retired zone IDs cannot be reused")
    } catch { #expect(error as? PostgresGameWorldError == .zoneRetired) }
    #expect(try await firstReplica.acquireLease(zoneID: thirdZone).zoneID == thirdZone)
}

@Test func postgresGameMatchmakingClaimsTicketsAcrossQueueReplicas() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PORT"] ?? "5432") ?? 5432
    let username = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_USER"] ?? "postgres"
    let databaseName = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_DATABASE"] ?? username
    let password = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PASSWORD"]
    let prefix = "pearfy_match_it_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let names = try ["\(prefix)_tickets", "\(prefix)_players", "\(prefix)_assignments", "\(prefix)_scan_state"].map { try SQLIdentifier($0).description }
    var postgres = PostgresClient.Configuration(host: host, port: port, username: username, password: password, database: databaseName, tls: .disable)
    postgres.options.maximumConnections = 4
    postgres.options.minimumConnections = 0
    let database = PearfyPostgresDatabase(configuration: postgres)
    try await database.start()
    do {
        let migration = try PostgresGameMatchmakingQueue.migration(tablePrefix: prefix)
        try await database.withTransaction { transaction in try await transaction.executeMigrationScript(migration.up) }
        let configuration = try PostgresGameMatchmakingConfiguration(queueID: "integration", maximumQueueEntries: 8, maximumQueuedPlayers: 16)
        let matching = try GameMatchmakingConfiguration(minimumPlayers: 2, maximumPlayers: 4, maximumQueueEntries: 8, maximumQueuedPlayers: 16)
        let firstReplica = try PostgresGameMatchmakingQueue(database: database, configuration: configuration, matchingConfiguration: matching, tablePrefix: prefix)
        let secondReplica = try PostgresGameMatchmakingQueue(database: database, configuration: configuration, matchingConfiguration: matching, tablePrefix: prefix)
        let partyA = GameMatchTicket(playerIDs: [UUID(), UUID()], mode: "coop", region: "local", skill: 100)
        let partyB = GameMatchTicket(playerIDs: [UUID()], mode: "coop", region: "local", skill: 120)
        try await firstReplica.enqueue(partyA)
        try await secondReplica.enqueue(partyB)

        let overlappingPlayerTicket = GameMatchTicket(playerIDs: [partyA.playerIDs[0]], mode: "coop", region: "local", skill: 100)
        do {
            try await secondReplica.enqueue(overlappingPlayerTicket)
            Issue.record("a player cannot be queued by two replicas at the same time")
        } catch { #expect(error as? PostgresGameMatchmakingError == .playerAlreadyQueued) }

        async let claimA = firstReplica.claimMatches()
        async let claimB = secondReplica.claimMatches()
        let deliveries = try await [claimA, claimB]
        let assignments = deliveries.flatMap { $0 }
        #expect(!assignments.isEmpty)
        #expect(Set(assignments.map(\.id)).count == 1)
        let assignment = try #require(assignments.first)
        #expect(Set(assignment.ticketIDs) == Set([partyA.id, partyB.id]))
        #expect(Set(assignment.playerIDs) == Set(partyA.playerIDs + partyB.playerIDs))
        do {
            try await secondReplica.enqueue(overlappingPlayerTicket)
            Issue.record("players remain reserved while an assignment is pending")
        } catch { #expect(error as? PostgresGameMatchmakingError == .playerAlreadyQueued) }
        #expect(try await firstReplica.acknowledge(assignmentID: assignment.id))
        #expect(try await secondReplica.claimMatches().isEmpty)

        let fairnessConfiguration = try PostgresGameMatchmakingConfiguration(
            queueID: "candidate-fairness", maximumQueueEntries: 8, maximumQueuedPlayers: 8,
            maximumCandidateTickets: 2
        )
        let fairnessQueue = try PostgresGameMatchmakingQueue(
            database: database,
            configuration: fairnessConfiguration,
            matchingConfiguration: matching,
            tablePrefix: prefix
        )
        let orderedTicketIDs = try (1...4).map { index in
            let suffix = String(index, radix: 16)
            let padded = String(repeating: "0", count: 12 - suffix.count) + suffix
            return try #require(UUID(uuidString: "00000000-0000-0000-0000-\(padded)"))
        }
        let fairnessTickets = [
            GameMatchTicket(id: orderedTicketIDs[0], playerIDs: [UUID()], mode: "solo-a", region: "local", skill: 100),
            GameMatchTicket(id: orderedTicketIDs[1], playerIDs: [UUID()], mode: "solo-b", region: "local", skill: 100),
            GameMatchTicket(id: orderedTicketIDs[2], playerIDs: [UUID()], mode: "coop", region: "local", skill: 100),
            GameMatchTicket(id: orderedTicketIDs[3], playerIDs: [UUID()], mode: "coop", region: "local", skill: 100)
        ]
        for ticket in fairnessTickets { try await fairnessQueue.enqueue(ticket) }
        #expect(try await fairnessQueue.claimMatches().isEmpty)
        let fairAssignment = try #require(await fairnessQueue.claimMatches().first)
        #expect(Set(fairAssignment.ticketIDs) == Set(orderedTicketIDs[2...3]))
        #expect(try await fairnessQueue.acknowledge(assignmentID: fairAssignment.id))

        let retryTicketIDs = try (5...6).map { index in
            let suffix = String(index, radix: 16)
            let padded = String(repeating: "0", count: 12 - suffix.count) + suffix
            return try #require(UUID(uuidString: "00000000-0000-0000-0000-\(padded)"))
        }
        for ticketID in retryTicketIDs {
            try await fairnessQueue.enqueue(GameMatchTicket(
                id: ticketID, playerIDs: [UUID()], mode: "retry", region: "local", skill: 100
            ))
        }
        let (attempts, attemptContinuation) = AsyncStream<UUID>.makeStream(bufferingPolicy: .bufferingNewest(2))
        var attemptIterator = attempts.makeAsyncIterator()
        do {
            _ = try await fairnessQueue.reconcilePendingAssignments(maximumAssignments: 1) { assignment in
                attemptContinuation.yield(assignment.id)
                throw PostgresGameMatchmakingError.invalidTicket
            }
            Issue.record("a failed allocator leaves the assignment pending")
        } catch {
            #expect(error as? PostgresGameMatchmakingError == .invalidTicket)
        }
        let firstDeliveryID = await attemptIterator.next()
        let reconciliation = try await fairnessQueue.reconcilePendingAssignments(maximumAssignments: 1) { assignment in
            attemptContinuation.yield(assignment.id)
        }
        let secondDeliveryID = await attemptIterator.next()
        attemptContinuation.finish()
        #expect(firstDeliveryID == secondDeliveryID)
        #expect(reconciliation.processedAssignments == 1)
        #expect(reconciliation.newlyAcknowledgedAssignments == 1)
        #expect(try await fairnessQueue.claimMatches().isEmpty)

        let expired = GameMatchTicket(playerIDs: [UUID()], mode: "coop", region: "local", skill: 100, enqueuedAt: Date(timeIntervalSince1970: 1))
        try await firstReplica.enqueue(expired)
        #expect(try await secondReplica.expireQueued(before: Date(timeIntervalSince1970: 2)) == 1)
        let pruned = try await firstReplica.pruneHistory(before: Date().addingTimeInterval(10))
        #expect(pruned.tickets == 3)
        #expect(pruned.assignments == 1)
        try await database.execute(SQLQuery(unsafeSQL: "DROP TABLE \(names[1]), \(names[0]), \(names[2]), \(names[3]) CASCADE"))
        try await database.stop()
    } catch {
        let drop = SQLQuery(unsafeSQL: "DROP TABLE IF EXISTS \(names[1]), \(names[0]), \(names[2]), \(names[3]) CASCADE")
        try? await database.execute(drop)
        try? await database.stop()
        throw error
    }
}

@Test func postgresGameStateMiddlewareCreatesBoundedTableAndUsesBoundParameters() async throws {
    let database = GameStateSQLDatabaseStub()
    let middleware = try PostgresGameServerStateMiddleware(database: database)
    let migration = try PostgresGameServerStateMiddleware.migration()
    let record = try GameServerStateRecord(namespace: "room", key: "alpha", revision: 7, payload: Data([1, 2, 3]))

    try await middleware.persist(record)
    try await middleware.persist(record)
    let queries = await database.queries()

    #expect(migration.id == "pearfy-game-server-state-v1")
    #expect(migration.up.statement.contains("CREATE TABLE IF NOT EXISTS \"pearfy_game_server_state\""))
    #expect(queries.count == 2)
    #expect(queries[0].statement.contains("ON CONFLICT (namespace, state_key)"))
    #expect(queries[0].statement.contains("WHERE \"pearfy_game_server_state\".revision < EXCLUDED.revision"))
    #expect(queries[0].parameters == [.text("room"), .text("alpha"), .integer(7), queries[0].parameters[3], .bytes(Data([1, 2, 3]))])
    #expect(queries[1].statement == queries[0].statement)
}

@Test func postgresGameStateMiddlewareRejectsUnsafeTableNamesAndOversizedRecords() async throws {
    let database = GameStateSQLDatabaseStub()
    #expect(throws: SQLQueryError.self) {
        try PostgresGameServerStateMiddleware(database: database, tableName: "state; DROP TABLE users")
    }
    let middleware = try PostgresGameServerStateMiddleware(database: database, maximumPayloadBytes: 1_024)
    let record = try GameServerStateRecord(namespace: "room", key: "alpha", revision: 1, payload: Data(repeating: 1, count: 1_025))
    do {
        try await middleware.persist(record)
        Issue.record("expected oversized state to be rejected")
    } catch {
        #expect(error as? PostgresGameServerStateError == .recordTooLarge)
    }
    #expect(await database.queries().isEmpty)
}

@Test func postgresGameStateMiddlewarePersistsManagerUpdatesOnTheConfiguredService() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PORT"] ?? "5432") ?? 5432
    let username = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_USER"] ?? "postgres"
    let databaseName = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_DATABASE"] ?? username
    let password = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PASSWORD"]
    let tableName = "pearfy_gs_state_it_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let table = try SQLIdentifier(tableName)
    var configuration = PostgresClient.Configuration(host: host, port: port, username: username, password: password, database: databaseName, tls: .disable)
    configuration.options.maximumConnections = 2
    configuration.options.minimumConnections = 0
    let database = PearfyPostgresDatabase(configuration: configuration)
    try await database.start()
    do {
        let migration = try PostgresGameServerStateMiddleware.migration(tableName: tableName)
        try await database.execute(migration.up)
        let middleware = try PostgresGameServerStateMiddleware(database: database, tableName: tableName)
        let manager = GameServerStateManager(maximumRetainedStates: 4, maximumPendingUpdates: 4)
        try await manager.start(middlewares: [middleware])
        let publisher = try await manager.publisher()
        let old = try GameServerStateRecord(namespace: "room", key: "live", revision: 1, payload: Data("old".utf8))
        let current = try GameServerStateRecord(namespace: "room", key: "live", revision: 2, payload: Data("current".utf8))
        #expect(publisher.publish(old) == .enqueued)
        #expect(publisher.publish(current) == .enqueued)
        await manager.stop()
        let revisions = try await database.queryStrings(SQLQuery(
            unsafeSQL: "SELECT revision::TEXT AS revision FROM \(table) WHERE namespace = $1 AND state_key = $2",
            parameters: [.text("room"), .text("live")]
        ), column: "revision")
        let payloads = try await database.queryStrings(SQLQuery(
            unsafeSQL: "SELECT encode(payload, 'escape') AS payload FROM \(table) WHERE namespace = $1 AND state_key = $2",
            parameters: [.text("room"), .text("live")]
        ), column: "payload")
        #expect(revisions == ["2"])
        #expect(payloads == ["current"])
        try await database.execute(SQLQuery(unsafeSQL: "DROP TABLE \(table)"))
        try await database.stop()
    } catch {
        try? await database.execute(SQLQuery(unsafeSQL: "DROP TABLE IF EXISTS \(table)"))
        try? await database.stop()
        throw error
    }
}

private actor GameStateSQLDatabaseStub: SQLDatabase {
    private var recorded: [SQLQuery] = []
    func execute(_ query: SQLQuery) async throws { recorded.append(query) }
    func queryStrings(_ query: SQLQuery, column: String) async throws -> [String] { [] }
    func withTransaction<Value: Sendable>(_ operation: @Sendable (any SQLTransaction) async throws -> Value) async throws -> Value {
        try await operation(GameStateSQLTransactionStub())
    }
    func withMigrationLock<Value: Sendable>(key: String, _ operation: @Sendable (any SQLTransaction) async throws -> Value) async throws -> Value {
        try await operation(GameStateSQLTransactionStub())
    }
    func queries() -> [SQLQuery] { recorded }
}

private struct GameStateSQLTransactionStub: SQLTransaction {
    func execute(_ query: SQLQuery) async throws { }
    func queryStrings(_ query: SQLQuery, column: String) async throws -> [String] { [] }
}

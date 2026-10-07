import Foundation
import PearfyData
import PearfyGameServer

public enum PostgresGameMatchmakingError: Error, Sendable, Equatable {
    case invalidConfiguration
    case invalidTicket
    case queueCapacityReached
    case playerAlreadyQueued
    case invalidStoredRecord
}

public struct PostgresGameMatchmakingConfiguration: Sendable, Equatable {
    public let queueID: String
    public let maximumQueueEntries: Int
    public let maximumQueuedPlayers: Int
    public let maximumCandidateTickets: Int
    public let maximumPendingAssignments: Int

    public init(queueID: String = "default", maximumQueueEntries: Int = 10_000,
                maximumQueuedPlayers: Int = 50_000, maximumCandidateTickets: Int = 1_000,
                maximumPendingAssignments: Int = 1_000) throws {
        guard !queueID.isEmpty, queueID.utf8.count <= 128,
              queueID.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
              }),
              (1...1_000_000).contains(maximumQueueEntries), (1...10_000_000).contains(maximumQueuedPlayers),
              (1...10_000).contains(maximumCandidateTickets), (1...100_000).contains(maximumPendingAssignments) else {
            throw PostgresGameMatchmakingError.invalidConfiguration
        }
        self.queueID = queueID
        self.maximumQueueEntries = maximumQueueEntries
        self.maximumQueuedPlayers = maximumQueuedPlayers
        self.maximumCandidateTickets = maximumCandidateTickets
        self.maximumPendingAssignments = maximumPendingAssignments
    }
}

public struct GameMatchAssignmentReconciliation: Sendable, Equatable {
    public let processedAssignments: Int
    public let newlyAcknowledgedAssignments: Int
}

/// PostgreSQL-backed matchmaking for replicas sharing one database. Queue mutations and
/// match claims use a transaction-scoped advisory lock per queue ID. Assignments are
/// retained until acknowledged and may be delivered more than once with the same ID.
public actor PostgresGameMatchmakingQueue {
    public typealias AssignmentHandler = @Sendable (GameMatchAssignment) async throws -> Void

    private let database: any SQLDatabase
    private let configuration: PostgresGameMatchmakingConfiguration
    private let matchingConfiguration: GameMatchmakingConfiguration
    private let ticketTable: String
    private let playerTable: String
    private let assignmentTable: String
    private let scanTable: String
    private var assignmentsInFlight: Set<UUID> = []

    public init(database: any SQLDatabase,
                configuration: PostgresGameMatchmakingConfiguration,
                matchingConfiguration: GameMatchmakingConfiguration = .standard,
                tablePrefix: String = "pearfy_game_match") throws {
        let names = try Self.tableNames(prefix: tablePrefix)
        self.database = database
        self.configuration = configuration
        self.matchingConfiguration = matchingConfiguration
        self.ticketTable = names.tickets
        self.playerTable = names.players
        self.assignmentTable = names.assignments
        self.scanTable = names.scanState
    }

    public static func migration(tablePrefix: String = "pearfy_game_match") throws -> SQLMigration {
        let names = try tableNames(prefix: tablePrefix)
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS \(names.tickets) (
                queue_id TEXT NOT NULL,
                ticket_id UUID NOT NULL,
                party_id UUID NOT NULL,
                status TEXT NOT NULL CHECK (status IN ('queued', 'assigned', 'cancelled', 'expired')),
                ticket_payload JSONB NOT NULL,
                enqueued_at TIMESTAMPTZ NOT NULL,
                assignment_id UUID,
                PRIMARY KEY (queue_id, ticket_id)
            )
            """,
            "CREATE UNIQUE INDEX IF NOT EXISTS \(names.ticketTableIndex("party")) ON \(names.tickets) (queue_id, party_id) WHERE status = 'queued'",
            "CREATE INDEX IF NOT EXISTS \(names.ticketTableIndex("queue")) ON \(names.tickets) (queue_id, status, enqueued_at, ticket_id)",
            "CREATE INDEX IF NOT EXISTS \(names.ticketTableIndex("scan")) ON \(names.tickets) (queue_id, status, ticket_id)",
            """
            CREATE TABLE IF NOT EXISTS \(names.players) (
                queue_id TEXT NOT NULL,
                player_id UUID NOT NULL,
                ticket_id UUID NOT NULL,
                PRIMARY KEY (queue_id, player_id),
                FOREIGN KEY (queue_id, ticket_id) REFERENCES \(names.tickets) (queue_id, ticket_id) ON DELETE CASCADE
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS \(names.assignments) (
                queue_id TEXT NOT NULL,
                assignment_id UUID NOT NULL,
                status TEXT NOT NULL CHECK (status IN ('pending', 'acknowledged')),
                assignment_payload JSONB NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                PRIMARY KEY (queue_id, assignment_id)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS \(names.scanState) (
                queue_id TEXT PRIMARY KEY,
                cursor_ticket_id UUID NOT NULL
            )
            """
        ]
        return SQLMigration(
            id: "pearfy-game-matchmaking-v2-\(names.rawPrefix.lowercased())",
            up: SQLQuery(unsafeSQL: statements.joined(separator: ";\n"))
        )
    }

    public func enqueue(_ ticket: GameMatchTicket) async throws {
        try validate(ticket)
        let payload = try Self.encode(ticket)
        try await database.withTransaction { transaction in
            try await self.lockQueue(transaction)
            let counts = try await self.queueCounts(transaction)
            guard counts.entries < self.configuration.maximumQueueEntries,
                  ticket.playerIDs.count <= self.configuration.maximumQueuedPlayers,
                  counts.players <= self.configuration.maximumQueuedPlayers - ticket.playerIDs.count else {
                throw PostgresGameMatchmakingError.queueCapacityReached
            }
            let duplicateParty = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "SELECT ticket_id::TEXT AS value FROM \(self.ticketTable) WHERE queue_id = $1 AND party_id = $2 AND status = 'queued' LIMIT 1",
                parameters: [.text(self.configuration.queueID), .uuid(ticket.partyID)]
            ), column: "value")
            guard duplicateParty.isEmpty else { throw PostgresGameMatchmakingError.invalidTicket }
            let playerArray = "{\(ticket.playerIDs.map(\.uuidString).joined(separator: ","))}"
            let duplicatePlayers = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "SELECT player_id::TEXT AS value FROM \(self.playerTable) WHERE queue_id = $1 AND player_id = ANY($2::UUID[]) LIMIT 1",
                parameters: [.text(self.configuration.queueID), .text(playerArray)]
            ), column: "value")
            guard duplicatePlayers.isEmpty else { throw PostgresGameMatchmakingError.playerAlreadyQueued }
            try await transaction.execute(SQLQuery(
                unsafeSQL: "INSERT INTO \(self.ticketTable) (queue_id, ticket_id, party_id, status, ticket_payload, enqueued_at) VALUES ($1, $2, $3, 'queued', $4::JSONB, to_timestamp($5::DOUBLE PRECISION))",
                parameters: [.text(self.configuration.queueID), .uuid(ticket.id), .uuid(ticket.partyID), .text(payload), .text(Self.timestamp(ticket.enqueuedAt))]
            ))
            for playerID in ticket.playerIDs {
                try await transaction.execute(SQLQuery(
                    unsafeSQL: "INSERT INTO \(self.playerTable) (queue_id, player_id, ticket_id) VALUES ($1, $2, $3)",
                    parameters: [.text(self.configuration.queueID), .uuid(playerID), .uuid(ticket.id)]
                ))
            }
        }
    }

    @discardableResult
    public func cancel(ticketID: UUID) async throws -> Bool {
        try await database.withTransaction { transaction in
            try await self.lockQueue(transaction)
            let rows = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "UPDATE \(self.ticketTable) SET status = 'cancelled' WHERE queue_id = $1 AND ticket_id = $2 AND status = 'queued' RETURNING ticket_id::TEXT AS value",
                parameters: [.text(self.configuration.queueID), .uuid(ticketID)]
            ), column: "value")
            guard !rows.isEmpty else { return false }
            try await transaction.execute(SQLQuery(
                unsafeSQL: "DELETE FROM \(self.playerTable) WHERE queue_id = $1 AND ticket_id = $2",
                parameters: [.text(self.configuration.queueID), .uuid(ticketID)]
            ))
            return true
        }
    }

    /// Returns pending assignments again until acknowledged, giving callers at-least-once
    /// delivery with a stable assignment ID. New tickets are claimed atomically by replicas.
    public func claimMatches(now: Date = Date(), maximumAssignments: Int? = nil) async throws -> [GameMatchAssignment] {
        let assignmentLimit = maximumAssignments ?? configuration.maximumPendingAssignments
        guard (1...configuration.maximumPendingAssignments).contains(assignmentLimit) else {
            throw PostgresGameMatchmakingError.invalidConfiguration
        }
        return try await database.withTransaction { transaction in
            try await self.lockQueue(transaction)
            let pendingPayloads = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "SELECT assignment_payload::TEXT AS value FROM \(self.assignmentTable) WHERE queue_id = $1 AND status = 'pending' ORDER BY created_at, assignment_id LIMIT $2 FOR UPDATE",
                parameters: [.text(self.configuration.queueID), .integer(Int64(assignmentLimit))]
            ), column: "value")
            var assignments = try pendingPayloads.map { try Self.decode(GameMatchAssignment.self, from: $0) }
            let availableSlots = max(0, assignmentLimit - assignments.count)
            guard availableSlots > 0 else { return assignments }

            let cursorValues = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "SELECT cursor_ticket_id::TEXT AS value FROM \(self.scanTable) WHERE queue_id = $1",
                parameters: [.text(self.configuration.queueID)]
            ), column: "value")
            guard cursorValues.count <= 1 else { throw PostgresGameMatchmakingError.invalidStoredRecord }
            let cursorTicketID: UUID?
            if let value = cursorValues.first {
                guard let decoded = UUID(uuidString: value) else { throw PostgresGameMatchmakingError.invalidStoredRecord }
                cursorTicketID = decoded
            } else {
                cursorTicketID = nil
            }

            var ticketPayloads: [String]
            if let cursorTicketID {
                ticketPayloads = try await transaction.queryStrings(SQLQuery(
                    unsafeSQL: "SELECT ticket_payload::TEXT AS value FROM \(self.ticketTable) WHERE queue_id = $1 AND status = 'queued' AND ticket_id > $2 ORDER BY ticket_id LIMIT $3 FOR UPDATE",
                    parameters: [.text(self.configuration.queueID), .uuid(cursorTicketID), .integer(Int64(self.configuration.maximumCandidateTickets))]
                ), column: "value")
                if ticketPayloads.count < self.configuration.maximumCandidateTickets {
                    let remaining = self.configuration.maximumCandidateTickets - ticketPayloads.count
                    let wrapped = try await transaction.queryStrings(SQLQuery(
                        unsafeSQL: "SELECT ticket_payload::TEXT AS value FROM \(self.ticketTable) WHERE queue_id = $1 AND status = 'queued' AND ticket_id <= $2 ORDER BY ticket_id LIMIT $3 FOR UPDATE",
                        parameters: [.text(self.configuration.queueID), .uuid(cursorTicketID), .integer(Int64(remaining))]
                    ), column: "value")
                    ticketPayloads.append(contentsOf: wrapped)
                }
            } else {
                ticketPayloads = try await transaction.queryStrings(SQLQuery(
                    unsafeSQL: "SELECT ticket_payload::TEXT AS value FROM \(self.ticketTable) WHERE queue_id = $1 AND status = 'queued' ORDER BY ticket_id LIMIT $2 FOR UPDATE",
                    parameters: [.text(self.configuration.queueID), .integer(Int64(self.configuration.maximumCandidateTickets))]
                ), column: "value")
            }

            let tickets = try ticketPayloads.map { try Self.decode(GameMatchTicket.self, from: $0) }
            if let lastScannedTicket = tickets.last {
                try await transaction.execute(SQLQuery(
                    unsafeSQL: "INSERT INTO \(self.scanTable) (queue_id, cursor_ticket_id) VALUES ($1, $2) ON CONFLICT (queue_id) DO UPDATE SET cursor_ticket_id = EXCLUDED.cursor_ticket_id",
                    parameters: [.text(self.configuration.queueID), .uuid(lastScannedTicket.id)]
                ))
            }
            let fairOrder = tickets.sorted {
                if $0.enqueuedAt != $1.enqueuedAt { return $0.enqueuedAt < $1.enqueuedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            let plan = GameMatchmakingPlanner.plan(tickets: fairOrder, configuration: self.matchingConfiguration, now: now)
            let newAssignments = Array(plan.assignments.prefix(availableSlots))
            for assignment in newAssignments {
                let payload = try Self.encode(assignment)
                try await transaction.execute(SQLQuery(
                    unsafeSQL: "INSERT INTO \(self.assignmentTable) (queue_id, assignment_id, status, assignment_payload) VALUES ($1, $2, 'pending', $3::JSONB)",
                    parameters: [.text(self.configuration.queueID), .uuid(assignment.id), .text(payload)]
                ))
                for ticketID in assignment.ticketIDs {
                    try await transaction.execute(SQLQuery(
                        unsafeSQL: "UPDATE \(self.ticketTable) SET status = 'assigned', assignment_id = $3 WHERE queue_id = $1 AND ticket_id = $2 AND status = 'queued'",
                        parameters: [.text(self.configuration.queueID), .uuid(ticketID), .uuid(assignment.id)]
                    ))
                }
                assignments.append(assignment)
            }
            return assignments
        }
    }

    /// Claims a bounded batch, invokes the application allocator outside a database
    /// transaction, then acknowledges successful assignments. Failed/ambiguous handler
    /// calls stay pending and are redelivered with the same ID on a later call.
    public func reconcilePendingAssignments(
        now: Date = Date(),
        maximumAssignments: Int = 100,
        ensureAssignment: @escaping AssignmentHandler
    ) async throws -> GameMatchAssignmentReconciliation {
        guard (1...1_000).contains(maximumAssignments) else {
            throw PostgresGameMatchmakingError.invalidConfiguration
        }
        let assignments = try await claimMatches(
            now: now,
            maximumAssignments: min(maximumAssignments, configuration.maximumPendingAssignments)
        )
        var processed = 0
        var acknowledged = 0
        for assignment in assignments.prefix(maximumAssignments) {
            guard assignmentsInFlight.insert(assignment.id).inserted else { continue }
            do {
                try await ensureAssignment(assignment)
                processed += 1
                if try await acknowledge(assignmentID: assignment.id) { acknowledged += 1 }
                assignmentsInFlight.remove(assignment.id)
            } catch {
                assignmentsInFlight.remove(assignment.id)
                throw error
            }
        }
        return GameMatchAssignmentReconciliation(
            processedAssignments: processed,
            newlyAcknowledgedAssignments: acknowledged
        )
    }

    @discardableResult
    public func acknowledge(assignmentID: UUID) async throws -> Bool {
        try await database.withTransaction { transaction in
            try await self.lockQueue(transaction)
            let payloads = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "SELECT assignment_payload::TEXT AS value FROM \(self.assignmentTable) WHERE queue_id = $1 AND assignment_id = $2 AND status = 'pending' FOR UPDATE",
                parameters: [.text(self.configuration.queueID), .uuid(assignmentID)]
            ), column: "value")
            guard let payload = payloads.first else { return false }
            let assignment = try Self.decode(GameMatchAssignment.self, from: payload)
            let rows = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "UPDATE \(self.assignmentTable) SET status = 'acknowledged' WHERE queue_id = $1 AND assignment_id = $2 AND status = 'pending' RETURNING assignment_id::TEXT AS value",
                parameters: [.text(self.configuration.queueID), .uuid(assignmentID)]
            ), column: "value")
            guard !rows.isEmpty else { return false }
            for ticketID in assignment.ticketIDs {
                try await transaction.execute(SQLQuery(
                    unsafeSQL: "DELETE FROM \(self.playerTable) WHERE queue_id = $1 AND ticket_id = $2",
                    parameters: [.text(self.configuration.queueID), .uuid(ticketID)]
                ))
            }
            return true
        }
    }

    /// Expires only queued tickets. Assigned tickets remain immutable until the app
    /// acknowledges/reconciles their assignment.
    public func expireQueued(before cutoff: Date, maximumTickets: Int = 1_000) async throws -> Int {
        guard (1...10_000).contains(maximumTickets) else { throw PostgresGameMatchmakingError.invalidConfiguration }
        return try await database.withTransaction { transaction in
            try await self.lockQueue(transaction)
            let rows = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "SELECT ticket_id::TEXT AS value FROM \(self.ticketTable) WHERE queue_id = $1 AND status = 'queued' AND enqueued_at < to_timestamp($2::DOUBLE PRECISION) ORDER BY enqueued_at, ticket_id LIMIT $3 FOR UPDATE",
                parameters: [.text(self.configuration.queueID), .text(Self.timestamp(cutoff)), .integer(Int64(maximumTickets))]
            ), column: "value")
            for row in rows {
                guard let ticketID = UUID(uuidString: row) else { throw PostgresGameMatchmakingError.invalidStoredRecord }
                try await transaction.execute(SQLQuery(
                    unsafeSQL: "UPDATE \(self.ticketTable) SET status = 'expired' WHERE queue_id = $1 AND ticket_id = $2 AND status = 'queued'",
                    parameters: [.text(self.configuration.queueID), .uuid(ticketID)]
                ))
                try await transaction.execute(SQLQuery(
                    unsafeSQL: "DELETE FROM \(self.playerTable) WHERE queue_id = $1 AND ticket_id = $2",
                    parameters: [.text(self.configuration.queueID), .uuid(ticketID)]
                ))
            }
            return rows.count
        }
    }

    /// Deletes only terminal ticket rows and acknowledged assignments older than cutoff.
    /// Each table deletion is independently bounded; queued and pending assignments survive.
    public func pruneHistory(before cutoff: Date, maximumRowsPerTable: Int = 1_000) async throws -> (tickets: Int, assignments: Int) {
        guard (1...10_000).contains(maximumRowsPerTable) else { throw PostgresGameMatchmakingError.invalidConfiguration }
        return try await database.withTransaction { transaction in
            try await self.lockQueue(transaction)
            let removedTickets = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: """
                WITH candidates AS (
                    SELECT ticket.ctid AS row_id
                    FROM \(self.ticketTable) AS ticket
                    LEFT JOIN \(self.assignmentTable) AS assignment
                      ON assignment.queue_id = ticket.queue_id AND assignment.assignment_id = ticket.assignment_id
                    WHERE ticket.queue_id = $1
                      AND ((ticket.status IN ('cancelled', 'expired') AND ticket.enqueued_at < to_timestamp($2::DOUBLE PRECISION))
                        OR (ticket.status = 'assigned' AND assignment.status = 'acknowledged' AND assignment.created_at < to_timestamp($2::DOUBLE PRECISION)))
                    ORDER BY ticket.enqueued_at, ticket.ticket_id
                    LIMIT $3
                    FOR UPDATE OF ticket SKIP LOCKED
                )
                DELETE FROM \(self.ticketTable) AS ticket USING candidates
                WHERE ticket.ctid = candidates.row_id
                RETURNING ticket.ticket_id::TEXT AS value
                """,
                parameters: [.text(self.configuration.queueID), .text(Self.timestamp(cutoff)), .integer(Int64(maximumRowsPerTable))]
            ), column: "value").count
            let removedAssignments = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: """
                WITH candidates AS (
                    SELECT assignment.ctid AS row_id
                    FROM \(self.assignmentTable) AS assignment
                    WHERE assignment.queue_id = $1 AND assignment.status = 'acknowledged'
                      AND assignment.created_at < to_timestamp($2::DOUBLE PRECISION)
                      AND NOT EXISTS (
                          SELECT 1 FROM \(self.ticketTable) AS ticket
                          WHERE ticket.queue_id = assignment.queue_id AND ticket.assignment_id = assignment.assignment_id
                      )
                    ORDER BY assignment.created_at, assignment.assignment_id
                    LIMIT $3
                    FOR UPDATE OF assignment SKIP LOCKED
                )
                DELETE FROM \(self.assignmentTable) AS assignment USING candidates
                WHERE assignment.ctid = candidates.row_id
                RETURNING assignment.assignment_id::TEXT AS value
                """,
                parameters: [.text(self.configuration.queueID), .text(Self.timestamp(cutoff)), .integer(Int64(maximumRowsPerTable))]
            ), column: "value").count
            return (removedTickets, removedAssignments)
        }
    }

    private func validate(_ ticket: GameMatchTicket) throws {
        guard !ticket.playerIDs.isEmpty, ticket.playerIDs.count <= matchingConfiguration.maximumPlayers,
              !ticket.mode.isEmpty, ticket.mode.utf8.count <= 64,
              !ticket.region.isEmpty, ticket.region.utf8.count <= 64,
              ticket.skill >= 0, ticket.skill <= 1_000_000_000,
              ticket.enqueuedAt.timeIntervalSince1970.isFinite,
              Set(ticket.playerIDs).count == ticket.playerIDs.count else {
            throw PostgresGameMatchmakingError.invalidTicket
        }
    }

    private func queueCounts(_ transaction: any SQLTransaction) async throws -> (entries: Int, players: Int) {
        let values = try await transaction.queryStrings(SQLQuery(
            unsafeSQL: "SELECT COUNT(*)::TEXT AS value FROM \(ticketTable) WHERE queue_id = $1 AND status = 'queued'",
            parameters: [.text(configuration.queueID)]
        ), column: "value")
        guard let entries = values.first.flatMap(Int.init) else { throw PostgresGameMatchmakingError.invalidStoredRecord }
        let playerValues = try await transaction.queryStrings(SQLQuery(
            unsafeSQL: "SELECT COUNT(*)::TEXT AS value FROM \(playerTable) WHERE queue_id = $1",
            parameters: [.text(configuration.queueID)]
        ), column: "value")
        guard let players = playerValues.first.flatMap(Int.init) else { throw PostgresGameMatchmakingError.invalidStoredRecord }
        return (entries, players)
    }

    private func lockQueue(_ transaction: any SQLTransaction) async throws {
        try await transaction.execute(SQLQuery(
            unsafeSQL: "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
            parameters: [.text("pearfy-game-matchmaking:\(configuration.queueID)")]
        ))
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let result = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw PostgresGameMatchmakingError.invalidStoredRecord
        }
        return result
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        guard let data = value.data(using: .utf8) else { throw PostgresGameMatchmakingError.invalidStoredRecord }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw PostgresGameMatchmakingError.invalidStoredRecord }
    }

    private static func timestamp(_ date: Date) -> String { String(date.timeIntervalSince1970) }

    private struct TableNames {
        let tickets: String
        let players: String
        let assignments: String
        let scanState: String
        let rawPrefix: String
        func ticketTableIndex(_ suffix: String) -> String {
            "\"\(rawPrefix)_\(suffix)_idx\""
        }
    }

    private static func tableNames(prefix: String) throws -> TableNames {
        guard !prefix.isEmpty, prefix.utf8.count <= 48,
              prefix.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95
              }) else { throw PostgresGameMatchmakingError.invalidConfiguration }
        let tickets = try SQLIdentifier("\(prefix)_tickets").description
        let players = try SQLIdentifier("\(prefix)_players").description
        let assignments = try SQLIdentifier("\(prefix)_assignments").description
        let scanState = try SQLIdentifier("\(prefix)_scan_state").description
        return TableNames(tickets: tickets, players: players, assignments: assignments, scanState: scanState, rawPrefix: prefix)
    }
}

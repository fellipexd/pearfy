import Foundation
import PearfyData
import PearfyGameServer
import PearfyGameServerTurnBased

public enum PostgresGameTurnBasedError: Error, Sendable, Equatable {
    case invalidConfiguration
    case invalidStoredRecord
    case eventTooLarge
    case historyCapacityReached
}

public struct PostgresGameTurnBasedConfiguration: Sendable, Equatable {
    public let maximumEvents: Int
    public let maximumStateBytes: Int
    public let maximumHistoryBytes: Int
    public let maximumCommandBytes: Int
    public let maximumEncodedEventBytes: Int

    public init(maximumEvents: Int = 10_000, maximumStateBytes: Int = 1_048_576,
                maximumHistoryBytes: Int = 67_108_864, maximumCommandBytes: Int = 65_536,
                maximumEncodedEventBytes: Int = 1_500_000) throws {
        guard (1...100_000).contains(maximumEvents),
              (1...16_777_216).contains(maximumStateBytes),
              (1...1_073_741_824).contains(maximumHistoryBytes),
              (1...1_048_576).contains(maximumCommandBytes),
              (1...32_000_000).contains(maximumEncodedEventBytes) else {
            throw PostgresGameTurnBasedError.invalidConfiguration
        }
        self.maximumEvents = maximumEvents
        self.maximumStateBytes = maximumStateBytes
        self.maximumHistoryBytes = maximumHistoryBytes
        self.maximumCommandBytes = maximumCommandBytes
        self.maximumEncodedEventBytes = maximumEncodedEventBytes
    }
}

/// Transactional PostgreSQL event store for finite turn-based sessions.
/// Events and the latest session state/revision are committed in one transaction.
public actor PostgresGameTurnBasedCommandStore: GameTurnBasedCommandStore {
    private struct SessionRow: Decodable {
        let revision: String
        let totalBytes: String
        let state: String
    }

    private let database: any SQLDatabase
    private let configuration: PostgresGameTurnBasedConfiguration
    private let sessionTable: String
    private let eventTable: String

    public init(database: any SQLDatabase, tablePrefix: String = "pearfy_gs_turn") throws {
        try self.init(database: database, configuration: PostgresGameTurnBasedConfiguration(), tablePrefix: tablePrefix)
    }

    public init(database: any SQLDatabase, configuration: PostgresGameTurnBasedConfiguration,
                tablePrefix: String = "pearfy_gs_turn") throws {
        guard (1...30).contains(tablePrefix.utf8.count) else { throw PostgresGameTurnBasedError.invalidConfiguration }
        guard tablePrefix == tablePrefix.lowercased() else { throw PostgresGameTurnBasedError.invalidConfiguration }
        let prefix = try SQLIdentifier(tablePrefix).rawValue
        self.database = database
        self.configuration = configuration
        self.sessionTable = try SQLIdentifier("\(prefix)_sessions").description
        self.eventTable = try SQLIdentifier("\(prefix)_events").description
    }

    public static func migration(tablePrefix: String = "pearfy_gs_turn") throws -> SQLMigration {
        guard (1...30).contains(tablePrefix.utf8.count) else { throw PostgresGameTurnBasedError.invalidConfiguration }
        guard tablePrefix == tablePrefix.lowercased() else { throw PostgresGameTurnBasedError.invalidConfiguration }
        let prefix = try SQLIdentifier(tablePrefix).rawValue
        let sessions = try SQLIdentifier("\(prefix)_sessions")
        let events = try SQLIdentifier("\(prefix)_events")
        return SQLMigration(
            id: "pearfy-game-turn-based-v1-\(prefix.lowercased())",
            up: SQLQuery(unsafeSQL: """
                CREATE TABLE IF NOT EXISTS \(sessions) (
                    session_id UUID PRIMARY KEY,
                    revision BIGINT NOT NULL CHECK (revision > 0),
                    total_bytes BIGINT NOT NULL CHECK (total_bytes >= 0),
                    state BYTEA NOT NULL
                );
                CREATE TABLE IF NOT EXISTS \(events) (
                    session_id UUID NOT NULL REFERENCES \(sessions)(session_id) ON DELETE CASCADE,
                    sequence BIGINT NOT NULL CHECK (sequence > 0),
                    command_id UUID NOT NULL,
                    player_id UUID NOT NULL,
                    command_payload BYTEA NOT NULL,
                    state BYTEA NOT NULL,
                    event_data JSONB NOT NULL,
                    PRIMARY KEY (session_id, sequence),
                    UNIQUE (session_id, command_id)
                )
                """))
    }

    public func load(sessionID: UUID) async throws -> GameStateCheckpoint? {
        try await database.withTransaction { transaction in
            try await transaction.execute(SQLQuery(
                unsafeSQL: "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                parameters: [.text(sessionID.uuidString.lowercased())]
            ))
            return try await self.load(sessionID: sessionID, using: transaction)
        }
    }

    private func load(sessionID: UUID, using transaction: any SQLTransaction) async throws -> GameStateCheckpoint? {
        let rows = try await transaction.queryStrings(SQLQuery(
            unsafeSQL: "SELECT json_build_object('revision', revision::TEXT, 'totalBytes', total_bytes::TEXT, 'state', encode(state, 'base64'))::TEXT AS value FROM \(sessionTable) WHERE session_id = $1",
            parameters: [.uuid(sessionID)]
        ), column: "value")
        guard let row = rows.first else {
            guard rows.isEmpty else { throw PostgresGameTurnBasedError.invalidStoredRecord }
            return nil
        }
        guard rows.count == 1, let session = try? JSONDecoder().decode(SessionRow.self, from: Data(row.utf8)),
              let revision = UInt64(session.revision), revision > 0,
              revision <= UInt64(configuration.maximumEvents),
              let totalBytes = Int(session.totalBytes), totalBytes >= 0,
              totalBytes <= configuration.maximumHistoryBytes,
              let state = Data(base64Encoded: session.state, options: .ignoreUnknownCharacters),
              state.count <= configuration.maximumStateBytes else {
            throw PostgresGameTurnBasedError.invalidStoredRecord
        }
        let countRows = try await transaction.queryStrings(SQLQuery(
            unsafeSQL: "SELECT count(*)::TEXT AS value FROM \(eventTable) WHERE session_id = $1",
            parameters: [.uuid(sessionID)]
        ), column: "value")
        guard countRows.count == 1, UInt64(countRows[0]) == revision else {
            throw PostgresGameTurnBasedError.invalidStoredRecord
        }
        let eventRows = try await transaction.queryStrings(SQLQuery(
            unsafeSQL: "SELECT event_data::TEXT AS value FROM \(eventTable) WHERE session_id = $1 ORDER BY sequence LIMIT $2",
            parameters: [.uuid(sessionID), .integer(Int64(configuration.maximumEvents + 1))]
        ), column: "value")
        guard eventRows.count == Int(revision) else { throw PostgresGameTurnBasedError.invalidStoredRecord }
        let events = try eventRows.map { row -> GameStateEvent in
            guard row.utf8.count <= configuration.maximumEncodedEventBytes,
                  let event = try? JSONDecoder().decode(GameStateEvent.self, from: Data(row.utf8)),
                  event.payload.count <= configuration.maximumCommandBytes,
                  event.state.count <= configuration.maximumStateBytes else {
                throw PostgresGameTurnBasedError.invalidStoredRecord
            }
            return event
        }
        let summedBytes = events.reduce(into: 0) { $0 += $1.payload.count + $1.state.count }
        guard summedBytes == totalBytes, events.last?.state == state else {
            throw PostgresGameTurnBasedError.invalidStoredRecord
        }
        return GameStateCheckpoint(revision: revision, state: state, events: events)
    }

    public func append(sessionID: UUID, expectedRevision: UInt64, event: GameStateEvent) async throws -> GameTurnBasedStoreResult {
        guard event.sequence <= UInt64(Int64.max), expectedRevision <= UInt64(Int64.max),
              event.sequence == expectedRevision + 1,
              event.payload.count <= configuration.maximumCommandBytes,
              event.state.count <= configuration.maximumStateBytes else {
            throw PostgresGameTurnBasedError.invalidConfiguration
        }
        let encoded = try JSONEncoder().encode(event)
        guard encoded.count <= configuration.maximumEncodedEventBytes else {
            throw PostgresGameTurnBasedError.eventTooLarge
        }
        let eventJSON = String(decoding: encoded, as: UTF8.self)
        let cost = event.payload.count + event.state.count
        guard cost <= configuration.maximumHistoryBytes else { throw PostgresGameTurnBasedError.historyCapacityReached }

        return try await database.withTransaction { transaction in
            // Hash collisions only serialize unrelated sessions; the UUID string is bound.
            try await transaction.execute(SQLQuery(
                unsafeSQL: "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                parameters: [.text(sessionID.uuidString.lowercased())]
            ))
            let duplicateRows = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "SELECT event_data::TEXT AS value FROM \(self.eventTable) WHERE session_id = $1 AND command_id = $2",
                parameters: [.uuid(sessionID), .uuid(event.commandID)]
            ), column: "value")
            if let duplicateJSON = duplicateRows.first {
                guard duplicateRows.count == 1,
                      let duplicate = try? JSONDecoder().decode(GameStateEvent.self, from: Data(duplicateJSON.utf8)),
                      duplicate.playerID == event.playerID, duplicate.payload == event.payload else {
                    throw GameServerError.commandIDConflict
                }
                let revisionRows = try await transaction.queryStrings(SQLQuery(
                    unsafeSQL: "SELECT revision::TEXT AS value FROM \(self.sessionTable) WHERE session_id = $1",
                    parameters: [.uuid(sessionID)]
                ), column: "value")
                guard revisionRows.count == 1, UInt64(revisionRows[0]) == duplicate.sequence,
                      duplicate.sequence == expectedRevision + 1 else {
                    throw GameServerError.revisionConflict(current: revisionRows.first.flatMap(UInt64.init) ?? 0)
                }
                return .duplicate(duplicate)
            }

            let sessionRows = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "SELECT json_build_object('revision', revision::TEXT, 'totalBytes', total_bytes::TEXT)::TEXT AS value FROM \(self.sessionTable) WHERE session_id = $1 FOR UPDATE",
                parameters: [.uuid(sessionID)]
            ), column: "value")
            let currentRevision: UInt64
            let currentBytes: Int
            if let currentJSON = sessionRows.first {
                guard sessionRows.count == 1,
                      let current = try? JSONDecoder().decode(CurrentRow.self, from: Data(currentJSON.utf8)),
                      let revision = UInt64(current.revision), let bytes = Int(current.totalBytes), bytes >= 0 else {
                    throw PostgresGameTurnBasedError.invalidStoredRecord
                }
                currentRevision = revision
                currentBytes = bytes
            } else {
                guard sessionRows.isEmpty else { throw PostgresGameTurnBasedError.invalidStoredRecord }
                currentRevision = 0
                currentBytes = 0
            }
            guard currentRevision == expectedRevision else {
                throw GameServerError.revisionConflict(current: currentRevision)
            }
            guard currentRevision < UInt64(configuration.maximumEvents),
                  currentBytes <= configuration.maximumHistoryBytes - cost else {
                throw PostgresGameTurnBasedError.historyCapacityReached
            }

            if currentRevision == 0 {
                try await transaction.execute(SQLQuery(
                    unsafeSQL: "INSERT INTO \(self.sessionTable) (session_id, revision, total_bytes, state) VALUES ($1, $2, $3, $4)",
                    parameters: [.uuid(sessionID), .integer(Int64(event.sequence)), .integer(Int64(cost)), .bytes(event.state)]
                ))
            } else {
                let updated = try await transaction.queryStrings(SQLQuery(
                    unsafeSQL: "UPDATE \(self.sessionTable) SET revision = $3, total_bytes = $4, state = $5 WHERE session_id = $1 AND revision = $2 RETURNING session_id::TEXT AS value",
                    parameters: [.uuid(sessionID), .integer(Int64(expectedRevision)), .integer(Int64(event.sequence)), .integer(Int64(currentBytes + cost)), .bytes(event.state)]
                ), column: "value")
                guard updated.count == 1 else { throw GameServerError.revisionConflict(current: currentRevision) }
            }
            try await transaction.execute(SQLQuery(
                unsafeSQL: "INSERT INTO \(self.eventTable) (session_id, sequence, command_id, player_id, command_payload, state, event_data) VALUES ($1, $2, $3, $4, $5, $6, $7::JSONB)",
                parameters: [.uuid(sessionID), .integer(Int64(event.sequence)), .uuid(event.commandID), .uuid(event.playerID), .bytes(event.payload), .bytes(event.state), .text(eventJSON)]
            ))
            return .appended(event)
        }
    }

    private struct CurrentRow: Decodable {
        let revision: String
        let totalBytes: String
    }
}

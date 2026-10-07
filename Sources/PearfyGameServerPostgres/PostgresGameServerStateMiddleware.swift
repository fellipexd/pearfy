import Foundation
import PearfyData
import PearfyGameServer

/// Asynchronous SQL sink for the bounded state manager. It stores only projected game
/// state and never runs on a simulation task. The caller owns database lifecycle/pooling.
public actor PostgresGameServerStateMiddleware: GameServerStateMiddleware {
    private let database: any SQLDatabase
    private let table: SQLIdentifier
    private let maximumPayloadBytes: Int

    public init(database: any SQLDatabase, tableName: String = "pearfy_game_server_state", maximumPayloadBytes: Int = 1_048_576) throws {
        guard (1...1_048_576).contains(maximumPayloadBytes) else { throw PostgresGameServerStateError.invalidConfiguration }
        self.database = database
        self.table = try SQLIdentifier(tableName)
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    /// Returns a versioned, additive migration. Apply it through the application's
    /// SQLMigrationCatalog/SQLMigrationRunner before starting the game server.
    public static func migration(tableName: String = "pearfy_game_server_state") throws -> SQLMigration {
        let table = try SQLIdentifier(tableName)
        return SQLMigration(id: "pearfy-game-server-state-v1", up: SQLQuery(unsafeSQL: """
            CREATE TABLE IF NOT EXISTS \(table) (
                namespace TEXT NOT NULL,
                state_key TEXT NOT NULL,
                revision BIGINT NOT NULL,
                updated_at TEXT NOT NULL,
                payload BYTEA NOT NULL,
                PRIMARY KEY (namespace, state_key)
            )
            """))
    }

    public func persist(_ record: GameServerStateRecord) async throws {
        guard record.payload.count <= maximumPayloadBytes, record.revision <= UInt64(Int64.max) else {
            throw PostgresGameServerStateError.recordTooLarge
        }
        let timestamp = ISO8601DateFormatter().string(from: record.updatedAt)
        try await database.execute(SQLQuery(
            unsafeSQL: """
                INSERT INTO \(table) (namespace, state_key, revision, updated_at, payload)
                VALUES ($1, $2, $3, $4, $5)
                ON CONFLICT (namespace, state_key) DO UPDATE SET
                    revision = EXCLUDED.revision,
                    updated_at = EXCLUDED.updated_at,
                    payload = EXCLUDED.payload
                WHERE \(table).revision < EXCLUDED.revision
                """,
            parameters: [
                .text(record.namespace), .text(record.key), .integer(Int64(record.revision)),
                .text(timestamp), .bytes(record.payload)
            ]
        ))
    }

    public func flush() async throws { }
}

public enum PostgresGameServerStateError: Error, Sendable, Equatable {
    case invalidConfiguration
    case recordTooLarge
}

import Foundation
import PearfyData
import PearfySocial
import PearfyPostgres
import PostgresNIO

/// PostgreSQL implementation for social actors and their follow/block graph.
/// Authorization inputs are the application's existing owner IDs; the adapter
/// does not create or merge identity records.
public struct PostgresSocialGraphStore: SocialGraphStore, Sendable {
    private static let actors = "\"pearfy_social_actors\""
    private static let follows = "\"pearfy_social_follows\""
    private static let blocks = "\"pearfy_social_blocks\""

    private let database: any SQLDatabase

    public init(database: any SQLDatabase) {
        self.database = database
    }

    public func installSchema() async throws {
        try await SQLMigrationRunner().apply(Self.migrations, to: database)
    }

    public func createActor(_ actor: SocialActor) async throws {
        try await database.execute(SQLQuery(
            unsafeSQL: """
            INSERT INTO \(Self.actors) (id, owner_id, actor_kind, handle, visibility)
            VALUES ($1, $2, $3, $4, $5)
            """,
            parameters: [
                .uuid(actor.id), .uuid(actor.ownerID), .text(actor.kind.rawValue),
                .text(actor.handle), .text(actor.visibility.rawValue)
            ]
        ))
    }

    public func follow(ownerID: UUID, sourceActorID: UUID, targetActorID: UUID) async throws -> SocialFollowStatus {
        guard sourceActorID != targetActorID else { throw SocialGraphError.selfRelationship }
        return try await withTransaction { transaction in
            try await Self.requireOwner(ownerID, of: sourceActorID, in: transaction)
            let visibility = try await Self.visibility(of: targetActorID, in: transaction)
            guard try await !Self.isBlocked(source: sourceActorID, target: targetActorID, in: transaction) else {
                throw SocialGraphError.blocked
            }
            let desiredStatus: SocialFollowStatus = visibility == .public ? .accepted : .pending
            try await transaction.execute(SQLQuery(
                unsafeSQL: """
                INSERT INTO \(Self.follows) (source_actor_id, target_actor_id, status)
                VALUES ($1, $2, $3)
                ON CONFLICT (source_actor_id, target_actor_id) DO NOTHING
                """,
                parameters: [.uuid(sourceActorID), .uuid(targetActorID), .text(desiredStatus.rawValue)]
            ))
            return try await Self.followStatus(source: sourceActorID, target: targetActorID, in: transaction)
        }
    }

    public func approveFollow(ownerID: UUID, sourceActorID: UUID, targetActorID: UUID) async throws {
        try await withTransaction { transaction in
            try await Self.requireOwner(ownerID, of: targetActorID, in: transaction)
            guard try await !Self.isBlocked(source: sourceActorID, target: targetActorID, in: transaction) else {
                throw SocialGraphError.blocked
            }
            let status = try await Self.followStatus(source: sourceActorID, target: targetActorID, in: transaction)
            guard status == .pending || status == .accepted else { throw SocialGraphError.actorNotFoundOrNotVisible }
            if status == .pending {
                try await transaction.execute(SQLQuery(
                    unsafeSQL: """
                    UPDATE \(Self.follows) SET status = 'accepted', updated_at = CURRENT_TIMESTAMP
                    WHERE source_actor_id = $1 AND target_actor_id = $2 AND status = 'pending'
                    """,
                    parameters: [.uuid(sourceActorID), .uuid(targetActorID)]
                ))
            }
        }
    }

    public func unfollow(ownerID: UUID, sourceActorID: UUID, targetActorID: UUID) async throws {
        try await withTransaction { transaction in
            try await Self.requireOwner(ownerID, of: sourceActorID, in: transaction)
            try await transaction.execute(SQLQuery(
                unsafeSQL: "DELETE FROM \(Self.follows) WHERE source_actor_id = $1 AND target_actor_id = $2",
                parameters: [.uuid(sourceActorID), .uuid(targetActorID)]
            ))
        }
    }

    public func block(ownerID: UUID, blockerActorID: UUID, blockedActorID: UUID) async throws {
        guard blockerActorID != blockedActorID else { throw SocialGraphError.selfRelationship }
        try await withTransaction { transaction in
            try await Self.requireOwner(ownerID, of: blockerActorID, in: transaction)
            _ = try await Self.visibility(of: blockedActorID, in: transaction)
            try await transaction.execute(SQLQuery(
                unsafeSQL: """
                INSERT INTO \(Self.blocks) (blocker_actor_id, blocked_actor_id)
                VALUES ($1, $2)
                ON CONFLICT (blocker_actor_id, blocked_actor_id) DO NOTHING
                """,
                parameters: [.uuid(blockerActorID), .uuid(blockedActorID)]
            ))
            try await transaction.execute(SQLQuery(
                unsafeSQL: """
                DELETE FROM \(Self.follows)
                WHERE (source_actor_id = $1 AND target_actor_id = $2)
                   OR (source_actor_id = $2 AND target_actor_id = $1)
                """,
                parameters: [.uuid(blockerActorID), .uuid(blockedActorID)]
            ))
        }
    }

    public func unblock(ownerID: UUID, blockerActorID: UUID, blockedActorID: UUID) async throws {
        try await withTransaction { transaction in
            try await Self.requireOwner(ownerID, of: blockerActorID, in: transaction)
            try await transaction.execute(SQLQuery(
                unsafeSQL: "DELETE FROM \(Self.blocks) WHERE blocker_actor_id = $1 AND blocked_actor_id = $2",
                parameters: [.uuid(blockerActorID), .uuid(blockedActorID)]
            ))
        }
    }

    public func canView(viewerOwnerID: UUID?, targetActorID: UUID) async throws -> Bool {
        let viewer: SQLValue = viewerOwnerID.map(SQLValue.uuid) ?? .null
        let result = try await database.queryStrings(SQLQuery(
            unsafeSQL: """
            SELECT CASE
                WHEN $1::UUID IS NULL THEN target.visibility = 'public'
                WHEN target.owner_id = $1 THEN TRUE
                WHEN EXISTS (
                    SELECT 1 FROM \(Self.blocks) b
                    JOIN \(Self.actors) blocker ON blocker.id = b.blocker_actor_id
                    WHERE blocker.owner_id = $1 AND b.blocked_actor_id = target.id
                ) THEN FALSE
                WHEN EXISTS (
                    SELECT 1 FROM \(Self.blocks) b
                    JOIN \(Self.actors) blocked ON blocked.id = b.blocked_actor_id
                    WHERE b.blocker_actor_id = target.id AND blocked.owner_id = $1
                ) THEN FALSE
                WHEN target.visibility = 'public' THEN TRUE
                WHEN target.visibility = 'followers' AND EXISTS (
                    SELECT 1 FROM \(Self.follows) f
                    JOIN \(Self.actors) viewer ON viewer.id = f.source_actor_id
                    WHERE viewer.owner_id = $1 AND f.target_actor_id = target.id AND f.status = 'accepted'
                ) THEN TRUE
                ELSE FALSE
            END::TEXT AS allowed
            FROM \(Self.actors) target
            WHERE target.id = $2 AND target.status = 'active'
            """,
            parameters: [viewer, .uuid(targetActorID)]
        ), column: "allowed")
        return result.first == "true"
    }

    private func withTransaction<Value: Sendable>(
        _ operation: @Sendable (any SQLTransaction) async throws -> Value
    ) async throws -> Value {
        do {
            return try await database.withTransaction(operation)
        } catch let error as PostgresTransactionError {
            if let socialError = error.closureError as? SocialGraphError { throw socialError }
            throw error
        }
    }

    private static func requireOwner(
        _ ownerID: UUID,
        of actorID: UUID,
        in transaction: any SQLTransaction
    ) async throws {
        let owners = try await transaction.queryStrings(SQLQuery(
            unsafeSQL: "SELECT id::TEXT AS id FROM \(actors) WHERE id = $1 AND owner_id = $2 AND status = 'active'",
            parameters: [.uuid(actorID), .uuid(ownerID)]
        ), column: "id")
        guard !owners.isEmpty else { throw SocialGraphError.actorOwnershipRequired }
    }

    private static func visibility(of actorID: UUID, in transaction: any SQLTransaction) async throws -> SocialVisibility {
        let values = try await transaction.queryStrings(SQLQuery(
            unsafeSQL: "SELECT visibility FROM \(actors) WHERE id = $1 AND status = 'active'",
            parameters: [.uuid(actorID)]
        ), column: "visibility")
        guard let raw = values.first, let visibility = SocialVisibility(rawValue: raw) else {
            throw SocialGraphError.actorNotFoundOrNotVisible
        }
        return visibility
    }

    private static func isBlocked(
        source: UUID,
        target: UUID,
        in transaction: any SQLTransaction
    ) async throws -> Bool {
        let values = try await transaction.queryStrings(SQLQuery(
            unsafeSQL: """
            SELECT EXISTS (
                SELECT 1 FROM \(blocks)
                WHERE (blocker_actor_id = $1 AND blocked_actor_id = $2)
                   OR (blocker_actor_id = $2 AND blocked_actor_id = $1)
            )::TEXT AS blocked
            """,
            parameters: [.uuid(source), .uuid(target)]
        ), column: "blocked")
        return values.first == "true"
    }

    private static func followStatus(
        source: UUID,
        target: UUID,
        in transaction: any SQLTransaction
    ) async throws -> SocialFollowStatus {
        let values = try await transaction.queryStrings(SQLQuery(
            unsafeSQL: "SELECT status FROM \(follows) WHERE source_actor_id = $1 AND target_actor_id = $2",
            parameters: [.uuid(source), .uuid(target)]
        ), column: "status")
        guard let raw = values.first, let status = SocialFollowStatus(rawValue: raw) else {
            throw SocialGraphError.actorNotFoundOrNotVisible
        }
        return status
    }

    private static let migrations: [SQLMigration] = [
        SQLMigration(
            id: "social-v1-actors",
            up: SQLQuery(unsafeSQL: """
            CREATE TABLE IF NOT EXISTS \(actors) (
                id UUID PRIMARY KEY,
                owner_id UUID NOT NULL,
                actor_kind TEXT NOT NULL CHECK (actor_kind IN ('person', 'page', 'community')),
                handle TEXT NOT NULL,
                visibility TEXT NOT NULL CHECK (visibility IN ('public', 'followers', 'private')),
                status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
                created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                UNIQUE (actor_kind, handle)
            )
            """),
            down: SQLQuery(unsafeSQL: "DROP TABLE IF EXISTS \(actors)")
        ),
        SQLMigration(
            id: "social-v1-actor-handle-check",
            up: SQLQuery(unsafeSQL: """
            ALTER TABLE \(actors)
            ADD CONSTRAINT pearfy_social_actors_handle_format CHECK (
                handle COLLATE "C" = lower(handle COLLATE "C")
                AND handle COLLATE "C" ~ '^[a-z0-9]([a-z0-9._-]{0,62}[a-z0-9])?$'
            )
            """),
            down: SQLQuery(unsafeSQL: """
            ALTER TABLE \(actors)
            DROP CONSTRAINT IF EXISTS pearfy_social_actors_handle_format
            """)
        ),
        SQLMigration(
            id: "social-v1-follows",
            up: SQLQuery(unsafeSQL: """
            CREATE TABLE IF NOT EXISTS \(follows) (
                source_actor_id UUID NOT NULL REFERENCES \(actors)(id) ON DELETE CASCADE,
                target_actor_id UUID NOT NULL REFERENCES \(actors)(id) ON DELETE CASCADE,
                status TEXT NOT NULL CHECK (status IN ('pending', 'accepted')),
                created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (source_actor_id, target_actor_id),
                CHECK (source_actor_id <> target_actor_id)
            )
            """),
            down: SQLQuery(unsafeSQL: "DROP TABLE IF EXISTS \(follows)")
        ),
        SQLMigration(
            id: "social-v1-blocks",
            up: SQLQuery(unsafeSQL: """
            CREATE TABLE IF NOT EXISTS \(blocks) (
                blocker_actor_id UUID NOT NULL REFERENCES \(actors)(id) ON DELETE CASCADE,
                blocked_actor_id UUID NOT NULL REFERENCES \(actors)(id) ON DELETE CASCADE,
                created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (blocker_actor_id, blocked_actor_id),
                CHECK (blocker_actor_id <> blocked_actor_id)
            )
            """),
            down: SQLQuery(unsafeSQL: "DROP TABLE IF EXISTS \(blocks)")
        )
    ]
}

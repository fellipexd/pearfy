import Crypto
import Foundation
import PearfyData
import PearfyPostgres
import PearfySocial
import PostgresNIO

/// PostgreSQL persistence for generic PearfySocial content. Application user
/// IDs remain opaque `owner_id` values; no game, catalog, XP, or account tables
/// are created or modified.
public struct PostgresSocialContentStore: SocialContentStore, Sendable {
    private static let actors = "\"pearfy_social_actors\""
    private static let follows = "\"pearfy_social_follows\""
    private static let blocks = "\"pearfy_social_blocks\""
    private static let posts = "\"pearfy_social_posts\""
    private static let comments = "\"pearfy_social_comments\""
    private static let reactions = "\"pearfy_social_reactions\""
    private static let moderationQueue = "\"pearfy_social_moderation_queue\""
    private static let moderationAudit = "\"pearfy_social_moderation_audit\""
    private static let notifications = "\"pearfy_social_notifications\""

    private let database: any SQLDatabase

    public init(database: any SQLDatabase) {
        self.database = database
    }

    /// Creates only Pearfy-prefixed schema. Applications decide when this
    /// additive migration set is reviewed and applied.
    public func installSchema() async throws {
        try await PostgresSocialGraphStore(database: database).installSchema()
        try await SQLMigrationRunner().apply(Self.migrations, to: database)
    }

    public func publish(_ draft: SocialPostDraft) async throws -> SocialPost {
        try await withTransaction { transaction in
            try await Self.requireOwner(draft.ownerID, actorID: draft.actorID, in: transaction)
            let digest = Self.sha256(draft.body)
            let inserted = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: """
                INSERT INTO \(Self.posts)
                    (id, actor_id, owner_id, body, visibility, moderation_status,
                     moderation_revision, content_digest, idempotency_key)
                VALUES ($1, $2, $3, $4, $5, 'pending', 1, $6, $7)
                ON CONFLICT (owner_id, idempotency_key) DO NOTHING
                RETURNING id::TEXT AS id
                """,
                parameters: [
                    .uuid(draft.id), .uuid(draft.actorID), .uuid(draft.ownerID), .text(draft.body),
                    .text(draft.visibility.rawValue), .text(digest), .text(draft.idempotencyKey)
                ]
            ), column: "id")

            guard let post = try await Self.post(
                ownerID: draft.ownerID,
                idempotencyKey: draft.idempotencyKey,
                in: transaction
            ) else {
                throw SocialContentError.postNotFoundOrNotVisible
            }
            guard post.actorID == draft.actorID,
                  post.body == draft.body,
                  post.visibility == draft.visibility else {
                throw SocialContentError.idempotencyKeyConflict
            }
            if !inserted.isEmpty {
                try await Self.enqueueModeration(
                    id: UUIDv7.generate(), kind: .post, contentID: post.id, ownerID: post.ownerID,
                    body: post.body, digest: digest, revision: post.moderationRevision, in: transaction
                )
            }
            return post
        }
    }

    public func comment(_ draft: SocialCommentDraft) async throws -> SocialComment {
        try await withTransaction { transaction in
            try await Self.requireOwner(draft.ownerID, actorID: draft.actorID, in: transaction)
            _ = try await Self.requireVisiblePost(
                draft.postID, viewerOwnerID: draft.ownerID, in: transaction
            )
            if let parentID = draft.parentCommentID {
                let parents = try await transaction.queryStrings(SQLQuery(
                    unsafeSQL: """
                    SELECT id::TEXT AS id FROM \(Self.comments)
                    WHERE id = $1 AND post_id = $2 AND deleted_at IS NULL
                    """,
                    parameters: [.uuid(parentID), .uuid(draft.postID)]
                ), column: "id")
                guard !parents.isEmpty else { throw SocialContentError.commentParentNotFound }
            }

            let digest = Self.sha256(draft.body)
            let inserted = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: """
                INSERT INTO \(Self.comments)
                    (id, post_id, parent_comment_id, actor_id, owner_id, body,
                     moderation_status, moderation_revision, content_digest, idempotency_key)
                VALUES ($1, $2, $3, $4, $5, $6, 'pending', 1, $7, $8)
                ON CONFLICT (owner_id, idempotency_key) DO NOTHING
                RETURNING id::TEXT AS id
                """,
                parameters: [
                    .uuid(draft.id), .uuid(draft.postID), draft.parentCommentID.map(SQLValue.uuid) ?? .null,
                    .uuid(draft.actorID), .uuid(draft.ownerID), .text(draft.body), .text(digest),
                    .text(draft.idempotencyKey)
                ]
            ), column: "id")
            guard let comment = try await Self.comment(
                ownerID: draft.ownerID,
                idempotencyKey: draft.idempotencyKey,
                in: transaction
            ) else {
                throw SocialContentError.postNotFoundOrNotVisible
            }
            guard comment.postID == draft.postID,
                  comment.parentCommentID == draft.parentCommentID,
                  comment.actorID == draft.actorID,
                  comment.body == draft.body else {
                throw SocialContentError.idempotencyKeyConflict
            }
            if !inserted.isEmpty {
                try await Self.enqueueModeration(
                    id: UUIDv7.generate(), kind: .comment, contentID: comment.id, ownerID: comment.ownerID,
                    body: comment.body, digest: digest, revision: comment.moderationRevision, in: transaction
                )
            }
            return comment
        }
    }

    @discardableResult
    public func setReaction(_ reaction: SocialReaction) async throws -> Bool {
        try await withTransaction { transaction in
            try await Self.requireOwner(reaction.ownerID, actorID: reaction.actorID, in: transaction)
            let postOwnerID = try await Self.requireVisiblePost(
                reaction.postID, viewerOwnerID: reaction.ownerID, requireApproved: true, in: transaction
            )
            guard postOwnerID != reaction.ownerID else { throw SocialContentError.ownPostReaction }
            let inserted = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: """
                INSERT INTO \(Self.reactions) (post_id, actor_id, owner_id, kind)
                VALUES ($1, $2, $3, $4)
                ON CONFLICT (post_id, actor_id, kind) DO NOTHING
                RETURNING post_id::TEXT AS id
                """,
                parameters: [
                    .uuid(reaction.postID), .uuid(reaction.actorID), .uuid(reaction.ownerID), .text(reaction.kind)
                ]
            ), column: "id")
            guard !inserted.isEmpty else { return false }
            try await Self.insertNotification(
                recipientOwnerID: postOwnerID,
                actorOwnerID: reaction.ownerID,
                kind: .reaction,
                entityKind: .post,
                entityID: reaction.postID,
                idempotencyKey: Self.notificationKey(
                    kind: "reaction-\(reaction.kind)", recipient: postOwnerID,
                    actor: reaction.ownerID, entity: reaction.postID
                ),
                in: transaction
            )
            return true
        }
    }

    @discardableResult
    public func removeReaction(_ reaction: SocialReaction) async throws -> Bool {
        try await withTransaction { transaction in
            try await Self.requireOwner(reaction.ownerID, actorID: reaction.actorID, in: transaction)
            _ = try await Self.requireVisiblePost(
                reaction.postID, viewerOwnerID: reaction.ownerID, requireApproved: true, in: transaction
            )
            let deleted = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: """
                DELETE FROM \(Self.reactions)
                WHERE post_id = $1 AND actor_id = $2 AND owner_id = $3 AND kind = $4
                RETURNING post_id::TEXT AS id
                """,
                parameters: [
                    .uuid(reaction.postID), .uuid(reaction.actorID), .uuid(reaction.ownerID), .text(reaction.kind)
                ]
            ), column: "id")
            return !deleted.isEmpty
        }
    }

    public func feed(_ request: SocialFeedRequest) async throws -> SocialFeedPage {
        var parameters: [SQLValue] = [request.viewerOwnerID.map(SQLValue.uuid) ?? .null]
        var cursorClause = ""
        if let cursor = request.cursor {
            let timestamp = Self.sqlTimestamp(cursor.createdAt)
            parameters += [.text(timestamp), .text(timestamp), .uuid(cursor.id)]
            let first = parameters.count - 2
            cursorClause = "AND (p.created_at < $\(first)::TIMESTAMPTZ OR (p.created_at = $\(first + 1)::TIMESTAMPTZ AND p.id < $\(first + 2)))"
        }
        let followingClause = request.scope == .following
            ? "AND ($1::UUID IS NOT NULL AND (p.owner_id = $1 OR \(Self.followedActorPredicate(viewer: "$1"))))"
            : ""
        parameters.append(.integer(Int64(request.limit + 1)))
        let limitIndex = parameters.count
        let rows = try await database.queryStrings(SQLQuery(
            unsafeSQL: """
            SELECT \(Self.postJSON(alias: "p")) AS content
            FROM \(Self.posts) p
            JOIN \(Self.actors) a ON a.id = p.actor_id AND a.status = 'active'
            WHERE p.deleted_at IS NULL
              AND (p.moderation_status = 'approved' OR p.owner_id = $1)
              AND \(Self.visibilityPredicate(viewer: "$1"))
              \(followingClause)
              \(cursorClause)
            ORDER BY p.created_at DESC, p.id DESC
            LIMIT $\(limitIndex)
            """,
            parameters: parameters
        ), column: "content")
        var items = try rows.map(Self.decodePost)
        let hasMore = items.count > request.limit
        if hasMore { items.removeLast() }
        let next = hasMore ? items.last.map { SocialFeedCursor(createdAt: $0.createdAt, id: $0.id) } : nil
        return SocialFeedPage(items: items, nextCursor: next)
    }

    public func comments(_ request: SocialCommentRequest) async throws -> SocialCommentPage {
        var parameters: [SQLValue] = [
            .uuid(request.postID), request.viewerOwnerID.map(SQLValue.uuid) ?? .null
        ]
        var cursorClause = ""
        if let cursor = request.cursor {
            let timestamp = Self.sqlTimestamp(cursor.createdAt)
            parameters += [.text(timestamp), .text(timestamp), .uuid(cursor.id)]
            let first = parameters.count - 2
            cursorClause = "AND (c.created_at > $\(first)::TIMESTAMPTZ OR (c.created_at = $\(first + 1)::TIMESTAMPTZ AND c.id > $\(first + 2)))"
        }
        parameters.append(.integer(Int64(request.limit + 1)))
        let limitIndex = parameters.count
        let rows = try await database.queryStrings(SQLQuery(
            unsafeSQL: """
            SELECT \(Self.commentJSON(alias: "c")) AS content
            FROM \(Self.comments) c
            WHERE c.post_id = $1 AND c.deleted_at IS NULL
              AND (c.moderation_status = 'approved' OR c.owner_id = $2)
              AND EXISTS (
                  SELECT 1 FROM \(Self.posts) p
                  JOIN \(Self.actors) a ON a.id = p.actor_id AND a.status = 'active'
                  WHERE p.id = c.post_id AND p.deleted_at IS NULL
                    AND (p.moderation_status = 'approved' OR p.owner_id = $2)
                    AND \(Self.visibilityPredicate(viewer: "$2"))
              )
              \(cursorClause)
            ORDER BY c.created_at ASC, c.id ASC
            LIMIT $\(limitIndex)
            """,
            parameters: parameters
        ), column: "content")
        var items = try rows.map(Self.decodeComment)
        let hasMore = items.count > request.limit
        if hasMore { items.removeLast() }
        let next = hasMore ? items.last.map { SocialFeedCursor(createdAt: $0.createdAt, id: $0.id) } : nil
        return SocialCommentPage(items: items, nextCursor: next)
    }

    public func notifications(_ request: SocialNotificationRequest) async throws -> SocialNotificationPage {
        var parameters: [SQLValue] = [.uuid(request.ownerID)]
        var cursorClause = ""
        if let cursor = request.cursor {
            let timestamp = Self.sqlTimestamp(cursor.createdAt)
            parameters += [.text(timestamp), .text(timestamp), .uuid(cursor.id)]
            let first = parameters.count - 2
            cursorClause = "AND (n.created_at < $\(first)::TIMESTAMPTZ OR (n.created_at = $\(first + 1)::TIMESTAMPTZ AND n.id < $\(first + 2)))"
        }
        parameters.append(.integer(Int64(request.limit + 1)))
        let limitIndex = parameters.count
        let rows = try await database.queryStrings(SQLQuery(
            unsafeSQL: """
            SELECT \(Self.notificationJSON(alias: "n")) AS content
            FROM \(Self.notifications) n
            WHERE n.recipient_owner_id = $1 \(cursorClause)
            ORDER BY n.created_at DESC, n.id DESC
            LIMIT $\(limitIndex)
            """,
            parameters: parameters
        ), column: "content")
        var items = try rows.map(Self.decodeNotification)
        let hasMore = items.count > request.limit
        if hasMore { items.removeLast() }
        let next = hasMore ? items.last.map { SocialFeedCursor(createdAt: $0.createdAt, id: $0.id) } : nil
        return SocialNotificationPage(items: items, nextCursor: next)
    }

    public func claimModeration(
        workerID: UUID,
        leaseDuration: Duration,
        maximumAttempts: Int
    ) async throws -> SocialModerationWorkItem? {
        guard leaseDuration > .zero, maximumAttempts > 0 else { throw SocialContentWorkerError.invalidConfiguration }
        let claimToken = UUIDv7.generate()
        let leaseSeconds = max(1, leaseDuration.components.seconds)
        let item = try await database.withTransaction { transaction -> SocialModerationWorkItem? in
            let rows = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: """
                SELECT json_build_object(
                    'id', q.id::TEXT, 'kind', q.content_kind, 'contentID', q.content_id::TEXT,
                    'ownerID', q.owner_id::TEXT, 'body', q.content, 'digest', q.digest,
                    'revision', q.revision, 'attempt', q.attempts + 1, 'claimToken', $1::TEXT
                )::TEXT AS content
                FROM \(Self.moderationQueue) q
                WHERE q.completed_at IS NULL
                  AND q.next_attempt_at <= CURRENT_TIMESTAMP
                  AND q.attempts < $2
                  AND (q.claimed_at IS NULL OR q.claimed_at < CURRENT_TIMESTAMP - ($3 * INTERVAL '1 second'))
                ORDER BY q.created_at, q.id
                LIMIT 1
                FOR UPDATE OF q SKIP LOCKED
                """,
                parameters: [.uuid(claimToken), .integer(Int64(maximumAttempts)), .integer(leaseSeconds)]
            ), column: "content")
            guard let json = rows.first else { return nil }
            let workItem = try Self.decodeModerationWorkItem(json)
            try await transaction.execute(SQLQuery(
                unsafeSQL: """
                UPDATE \(Self.moderationQueue)
                SET claimed_at = CURRENT_TIMESTAMP, claimed_by = $2, claim_token = $3,
                    attempts = attempts + 1
                WHERE id = $1 AND completed_at IS NULL
                """,
                parameters: [.uuid(workItem.id), .uuid(workerID), .uuid(claimToken)]
            ))
            return workItem
        }
        return item
    }

    public func completeModeration(
        _ item: SocialModerationWorkItem,
        decision: SocialModerationDecision
    ) async throws -> Bool {
        try await withTransaction { transaction in
            let claimed = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: """
                SELECT id::TEXT AS id FROM \(Self.moderationQueue)
                WHERE id = $1 AND claim_token = $2 AND completed_at IS NULL
                FOR UPDATE
                """,
                parameters: [.uuid(item.id), .uuid(item.claimToken)]
            ), column: "id")
            guard !claimed.isEmpty else { return false }
            let changed = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: """
                UPDATE \(Self.contentTable(item.kind))
                SET moderation_status = $1, moderation_reason = $2, moderation_checked_at = CURRENT_TIMESTAMP
                WHERE id = $3 AND moderation_revision = $4 AND content_digest = $5 AND deleted_at IS NULL
                RETURNING id::TEXT AS id
                """,
                parameters: [
                    .text(decision.result.rawValue), decision.reason.map(SQLValue.text) ?? .null,
                    .uuid(item.contentID), .integer(item.revision), .text(item.digest)
                ]
            ), column: "id")
            if !changed.isEmpty {
                try await transaction.execute(SQLQuery(
                    unsafeSQL: """
                    INSERT INTO \(Self.moderationAudit)
                        (id, queue_id, content_kind, content_id, provider, result, reason)
                    VALUES ($1, $2, $3, $4, $5, $6, $7)
                    ON CONFLICT (queue_id) DO NOTHING
                    """,
                    parameters: [
                        .uuid(UUIDv7.generate()), .uuid(item.id), .text(item.kind.rawValue),
                        .uuid(item.contentID), .text(decision.provider), .text(decision.result.rawValue),
                        decision.reason.map(SQLValue.text) ?? .null
                    ]
                ))
                if decision.result == .approved, item.kind == .comment {
                    let recipients = try await transaction.queryStrings(SQLQuery(
                        unsafeSQL: """
                        SELECT p.owner_id::TEXT AS owner_id
                        FROM \(Self.comments) c
                        JOIN \(Self.posts) p ON p.id = c.post_id
                        WHERE c.id = $1 AND c.deleted_at IS NULL AND p.deleted_at IS NULL
                        """,
                        parameters: [.uuid(item.contentID)]
                    ), column: "owner_id")
                    if let rawOwnerID = recipients.first,
                       let recipientOwnerID = UUID(uuidString: rawOwnerID),
                       recipientOwnerID != item.ownerID {
                        let postIDs = try await transaction.queryStrings(SQLQuery(
                            unsafeSQL: "SELECT post_id::TEXT AS post_id FROM \(Self.comments) WHERE id = $1",
                            parameters: [.uuid(item.contentID)]
                        ), column: "post_id")
                        if let rawPostID = postIDs.first, let postID = UUID(uuidString: rawPostID) {
                            try await Self.insertNotification(
                                recipientOwnerID: recipientOwnerID,
                                actorOwnerID: item.ownerID,
                                kind: .comment,
                                entityKind: .post,
                                entityID: postID,
                                idempotencyKey: Self.notificationKey(
                                    kind: "comment", recipient: recipientOwnerID, actor: item.ownerID,
                                    entity: postID, detail: item.contentID
                                ),
                                in: transaction
                            )
                        }
                    }
                }
            }
            try await transaction.execute(SQLQuery(
                unsafeSQL: """
                UPDATE \(Self.moderationQueue)
                SET completed_at = CURRENT_TIMESTAMP, claimed_at = NULL, claimed_by = NULL,
                    claim_token = NULL, last_error = NULL
                WHERE id = $1 AND claim_token = $2 AND completed_at IS NULL
                """,
                parameters: [.uuid(item.id), .uuid(item.claimToken)]
            ))
            return !changed.isEmpty
        }
    }

    public func retryModeration(
        _ item: SocialModerationWorkItem,
        errorCode: String,
        maximumAttempts: Int
    ) async throws {
        guard maximumAttempts > 0 else { throw SocialContentWorkerError.invalidConfiguration }
        try await withTransaction { transaction in
            let current = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: """
                SELECT attempts::TEXT AS attempts FROM \(Self.moderationQueue)
                WHERE id = $1 AND claim_token = $2 AND completed_at IS NULL FOR UPDATE
                """,
                parameters: [.uuid(item.id), .uuid(item.claimToken)]
            ), column: "attempts")
            guard let rawAttempts = current.first, let attempts = Int(rawAttempts) else { return }
            let safeCode = String(errorCode.filter {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-")
            }.prefix(120))
            if attempts >= maximumAttempts {
                try await transaction.execute(SQLQuery(
                    unsafeSQL: """
                    UPDATE \(Self.contentTable(item.kind))
                    SET moderation_status = 'error', moderation_reason = $1, moderation_checked_at = CURRENT_TIMESTAMP
                    WHERE id = $2 AND moderation_revision = $3 AND content_digest = $4 AND deleted_at IS NULL
                    """,
                    parameters: [.text(safeCode), .uuid(item.contentID), .integer(item.revision), .text(item.digest)]
                ))
                try await transaction.execute(SQLQuery(
                    unsafeSQL: """
                    UPDATE \(Self.moderationQueue)
                    SET completed_at = CURRENT_TIMESTAMP, claimed_at = NULL, claimed_by = NULL,
                        claim_token = NULL, last_error = $3
                    WHERE id = $1 AND claim_token = $2 AND completed_at IS NULL
                    """,
                    parameters: [.uuid(item.id), .uuid(item.claimToken), .text(safeCode)]
                ))
            } else {
                let backoff = min(86_400, 5 * (1 << min(14, max(0, attempts - 1))))
                try await transaction.execute(SQLQuery(
                    unsafeSQL: """
                    UPDATE \(Self.moderationQueue)
                    SET claimed_at = NULL, claimed_by = NULL, claim_token = NULL,
                        last_error = $3, next_attempt_at = CURRENT_TIMESTAMP + ($4 * INTERVAL '1 second')
                    WHERE id = $1 AND claim_token = $2 AND completed_at IS NULL
                    """,
                    parameters: [.uuid(item.id), .uuid(item.claimToken), .text(safeCode), .integer(Int64(backoff))]
                ))
            }
        }
    }

    private func withTransaction<Value: Sendable>(
        _ operation: @Sendable (any SQLTransaction) async throws -> Value
    ) async throws -> Value {
        do {
            return try await database.withTransaction(operation)
        } catch let error as PostgresTransactionError {
            if let contentError = error.closureError as? SocialContentError { throw contentError }
            if let graphError = error.closureError as? SocialGraphError { throw graphError }
            throw error
        }
    }

    private static func requireOwner(_ ownerID: UUID, actorID: UUID, in transaction: any SQLTransaction) async throws {
        let values = try await transaction.queryStrings(SQLQuery(
            unsafeSQL: "SELECT id::TEXT AS id FROM \(actors) WHERE id = $1 AND owner_id = $2 AND status = 'active'",
            parameters: [.uuid(actorID), .uuid(ownerID)]
        ), column: "id")
        guard !values.isEmpty else { throw SocialGraphError.actorOwnershipRequired }
    }

    private static func requireVisiblePost(
        _ postID: UUID,
        viewerOwnerID: UUID,
        requireApproved: Bool = false,
        in transaction: any SQLTransaction
    ) async throws -> UUID {
        let status = requireApproved ? "p.moderation_status = 'approved'" : "(p.moderation_status = 'approved' OR p.owner_id = $2)"
        let values = try await transaction.queryStrings(SQLQuery(
            unsafeSQL: """
            SELECT p.owner_id::TEXT AS owner_id FROM \(posts) p
            JOIN \(actors) a ON a.id = p.actor_id AND a.status = 'active'
            WHERE p.id = $1 AND p.deleted_at IS NULL AND \(status)
              AND \(visibilityPredicate(viewer: "$2"))
            """,
            parameters: [.uuid(postID), .uuid(viewerOwnerID)]
        ), column: "owner_id")
        guard let raw = values.first, let owner = UUID(uuidString: raw) else {
            throw SocialContentError.postNotFoundOrNotVisible
        }
        return owner
    }

    private static func enqueueModeration(
        id: UUID,
        kind: SocialContentKind,
        contentID: UUID,
        ownerID: UUID,
        body: String,
        digest: String,
        revision: Int64,
        in transaction: any SQLTransaction
    ) async throws {
        try await transaction.execute(SQLQuery(
            unsafeSQL: """
            INSERT INTO \(moderationQueue)
                (id, content_kind, content_id, owner_id, content, digest, revision)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            ON CONFLICT (content_kind, content_id, digest, revision) DO NOTHING
            """,
            parameters: [
                .uuid(id), .text(kind.rawValue), .uuid(contentID), .uuid(ownerID), .text(body),
                .text(digest), .integer(revision)
            ]
        ))
    }

    private static func insertNotification(
        recipientOwnerID: UUID,
        actorOwnerID: UUID,
        kind: SocialNotificationKind,
        entityKind: SocialNotificationEntityKind,
        entityID: UUID,
        idempotencyKey: String,
        in transaction: any SQLTransaction
    ) async throws {
        try await transaction.execute(SQLQuery(
            unsafeSQL: """
            INSERT INTO \(notifications)
                (id, recipient_owner_id, actor_owner_id, notification_kind, entity_kind, entity_id, idempotency_key)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            ON CONFLICT (idempotency_key) DO NOTHING
            """,
            parameters: [
                .uuid(UUIDv7.generate()), .uuid(recipientOwnerID), .uuid(actorOwnerID),
                .text(kind.rawValue), .text(entityKind.rawValue), .uuid(entityID), .text(idempotencyKey)
            ]
        ))
    }

    private static func post(ownerID: UUID, idempotencyKey: String, in transaction: any SQLTransaction) async throws -> SocialPost? {
        let rows = try await transaction.queryStrings(SQLQuery(
            unsafeSQL: "SELECT \(postJSON(alias: "p")) AS content FROM \(posts) p WHERE p.owner_id = $1 AND p.idempotency_key = $2",
            parameters: [.uuid(ownerID), .text(idempotencyKey)]
        ), column: "content")
        return try rows.first.map(decodePost)
    }

    private static func comment(ownerID: UUID, idempotencyKey: String, in transaction: any SQLTransaction) async throws -> SocialComment? {
        let rows = try await transaction.queryStrings(SQLQuery(
            unsafeSQL: "SELECT \(commentJSON(alias: "c")) AS content FROM \(comments) c WHERE c.owner_id = $1 AND c.idempotency_key = $2",
            parameters: [.uuid(ownerID), .text(idempotencyKey)]
        ), column: "content")
        return try rows.first.map(decodeComment)
    }

    private static func visibilityPredicate(viewer: String) -> String {
        """
        (p.owner_id = \(viewer) OR (
            p.visibility <> 'private' AND a.visibility <> 'private'
            AND ((p.visibility = 'public' AND a.visibility = 'public')
                 OR \(followedActorPredicate(viewer: viewer)))
        ))
        AND (\(viewer)::UUID IS NULL OR NOT EXISTS (
            SELECT 1 FROM \(blocks) b
            JOIN \(actors) blocker ON blocker.id = b.blocker_actor_id
            JOIN \(actors) blocked ON blocked.id = b.blocked_actor_id
            WHERE (blocker.owner_id = \(viewer) AND b.blocked_actor_id = a.id)
               OR (b.blocker_actor_id = a.id AND blocked.owner_id = \(viewer))
        ))
        """
    }

    private static func followedActorPredicate(viewer: String) -> String {
        """
        EXISTS (
            SELECT 1 FROM \(follows) f
            JOIN \(actors) viewer_actor ON viewer_actor.id = f.source_actor_id
            WHERE viewer_actor.owner_id = \(viewer)
              AND f.target_actor_id = a.id AND f.status = 'accepted'
        )
        """
    }

    private static func postJSON(alias: String) -> String {
        """
        json_build_object(
            'id', \(alias).id::TEXT, 'actorID', \(alias).actor_id::TEXT,
            'ownerID', \(alias).owner_id::TEXT, 'body', \(alias).body,
            'visibility', \(alias).visibility, 'moderationStatus', \(alias).moderation_status,
            'moderationRevision', \(alias).moderation_revision,
            'createdAtReferenceSeconds', EXTRACT(EPOCH FROM \(alias).created_at) - 978307200,
            'updatedAtReferenceSeconds', EXTRACT(EPOCH FROM \(alias).updated_at) - 978307200
        )::TEXT
        """
    }

    private static func commentJSON(alias: String) -> String {
        """
        json_build_object(
            'id', \(alias).id::TEXT, 'postID', \(alias).post_id::TEXT,
            'parentCommentID', \(alias).parent_comment_id::TEXT,
            'actorID', \(alias).actor_id::TEXT, 'ownerID', \(alias).owner_id::TEXT,
            'body', \(alias).body, 'moderationStatus', \(alias).moderation_status,
            'moderationRevision', \(alias).moderation_revision,
            'createdAtReferenceSeconds', EXTRACT(EPOCH FROM \(alias).created_at) - 978307200,
            'updatedAtReferenceSeconds', EXTRACT(EPOCH FROM \(alias).updated_at) - 978307200
        )::TEXT
        """
    }

    private static func notificationJSON(alias: String) -> String {
        """
        json_build_object(
            'id', \(alias).id::TEXT, 'recipientOwnerID', \(alias).recipient_owner_id::TEXT,
            'actorOwnerID', \(alias).actor_owner_id::TEXT, 'kind', \(alias).notification_kind,
            'entityKind', \(alias).entity_kind, 'entityID', \(alias).entity_id::TEXT,
            'idempotencyKey', \(alias).idempotency_key,
            'createdAtReferenceSeconds', EXTRACT(EPOCH FROM \(alias).created_at) - 978307200
        )::TEXT
        """
    }

    private static func decodePost(_ json: String) throws -> SocialPost {
        let row = try JSONDecoder().decode(PersistedPost.self, from: Data(json.utf8))
        guard let id = UUID(uuidString: row.id), let actorID = UUID(uuidString: row.actorID),
              let ownerID = UUID(uuidString: row.ownerID),
              let visibility = SocialVisibility(rawValue: row.visibility),
              let status = SocialContentStatus(rawValue: row.moderationStatus) else {
            throw SocialContentError.postNotFoundOrNotVisible
        }
        return try SocialPost(
            id: id, actorID: actorID, ownerID: ownerID, body: row.body, visibility: visibility,
            moderationStatus: status, moderationRevision: row.moderationRevision,
            createdAt: Date(timeIntervalSinceReferenceDate: row.createdAtReferenceSeconds),
            updatedAt: Date(timeIntervalSinceReferenceDate: row.updatedAtReferenceSeconds)
        )
    }

    private static func decodeComment(_ json: String) throws -> SocialComment {
        let row = try JSONDecoder().decode(PersistedComment.self, from: Data(json.utf8))
        guard let id = UUID(uuidString: row.id), let postID = UUID(uuidString: row.postID),
              let actorID = UUID(uuidString: row.actorID), let ownerID = UUID(uuidString: row.ownerID),
              let status = SocialContentStatus(rawValue: row.moderationStatus) else {
            throw SocialContentError.postNotFoundOrNotVisible
        }
        return try SocialComment(
            id: id, postID: postID, parentCommentID: row.parentCommentID.flatMap(UUID.init(uuidString:)),
            actorID: actorID, ownerID: ownerID, body: row.body, moderationStatus: status,
            moderationRevision: row.moderationRevision,
            createdAt: Date(timeIntervalSinceReferenceDate: row.createdAtReferenceSeconds),
            updatedAt: Date(timeIntervalSinceReferenceDate: row.updatedAtReferenceSeconds)
        )
    }

    private static func decodeNotification(_ json: String) throws -> SocialNotification {
        let row = try JSONDecoder().decode(PersistedNotification.self, from: Data(json.utf8))
        guard let id = UUID(uuidString: row.id), let recipient = UUID(uuidString: row.recipientOwnerID),
              let actor = UUID(uuidString: row.actorOwnerID), let entityID = UUID(uuidString: row.entityID),
              let kind = SocialNotificationKind(rawValue: row.kind),
              let entityKind = SocialNotificationEntityKind(rawValue: row.entityKind) else {
            throw SocialContentError.invalidIdempotencyKey
        }
        return try SocialNotification(
            id: id, recipientOwnerID: recipient, actorOwnerID: actor, kind: kind,
            entityKind: entityKind, entityID: entityID, idempotencyKey: row.idempotencyKey,
            createdAt: Date(timeIntervalSinceReferenceDate: row.createdAtReferenceSeconds)
        )
    }

    private static func decodeModerationWorkItem(_ json: String) throws -> SocialModerationWorkItem {
        let row = try JSONDecoder().decode(PersistedModerationItem.self, from: Data(json.utf8))
        guard let id = UUID(uuidString: row.id), let contentID = UUID(uuidString: row.contentID),
              let ownerID = UUID(uuidString: row.ownerID), let claimToken = UUID(uuidString: row.claimToken),
              let kind = SocialContentKind(rawValue: row.kind) else {
            throw SocialContentError.invalidModerationDigest
        }
        return try SocialModerationWorkItem(
            id: id, kind: kind, contentID: contentID, ownerID: ownerID, body: row.body,
            digest: row.digest, revision: row.revision, attempt: row.attempt, claimToken: claimToken
        )
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func sqlTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func notificationKey(
        kind: String,
        recipient: UUID,
        actor: UUID,
        entity: UUID,
        detail: UUID? = nil
    ) -> String {
        ["social", kind, recipient.uuidString.lowercased(), actor.uuidString.lowercased(),
         entity.uuidString.lowercased(), detail?.uuidString.lowercased()]
            .compactMap { $0 }
            .joined(separator: ":")
    }

    private static func contentTable(_ kind: SocialContentKind) -> String {
        switch kind {
        case .post: posts
        case .comment: comments
        }
    }

    private struct PersistedPost: Decodable {
        let id: String
        let actorID: String
        let ownerID: String
        let body: String
        let visibility: String
        let moderationStatus: String
        let moderationRevision: Int64
        let createdAtReferenceSeconds: Double
        let updatedAtReferenceSeconds: Double
    }

    private struct PersistedComment: Decodable {
        let id: String
        let postID: String
        let parentCommentID: String?
        let actorID: String
        let ownerID: String
        let body: String
        let moderationStatus: String
        let moderationRevision: Int64
        let createdAtReferenceSeconds: Double
        let updatedAtReferenceSeconds: Double
    }

    private struct PersistedNotification: Decodable {
        let id: String
        let recipientOwnerID: String
        let actorOwnerID: String
        let kind: String
        let entityKind: String
        let entityID: String
        let idempotencyKey: String
        let createdAtReferenceSeconds: Double
    }

    private struct PersistedModerationItem: Decodable {
        let id: String
        let kind: String
        let contentID: String
        let ownerID: String
        let body: String
        let digest: String
        let revision: Int64
        let attempt: Int
        let claimToken: String
    }

    private static let migrations: [SQLMigration] = [
        SQLMigration(id: "social-content-v1-01-posts", up: SQLQuery(unsafeSQL: """
            CREATE TABLE IF NOT EXISTS \(posts) (
                id UUID PRIMARY KEY,
                actor_id UUID NOT NULL REFERENCES \(actors)(id) ON DELETE CASCADE,
                owner_id UUID NOT NULL,
                body TEXT NOT NULL CHECK (length(trim(body)) BETWEEN 1 AND 5000),
                visibility TEXT NOT NULL CHECK (visibility IN ('public','followers','private')),
                moderation_status TEXT NOT NULL DEFAULT 'pending' CHECK (moderation_status IN ('pending','approved','rejected','error')),
                moderation_revision BIGINT NOT NULL DEFAULT 1 CHECK (moderation_revision > 0),
                content_digest TEXT NOT NULL,
                idempotency_key TEXT NOT NULL,
                moderation_reason TEXT,
                moderation_checked_at TIMESTAMPTZ,
                created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                deleted_at TIMESTAMPTZ,
                UNIQUE (owner_id, idempotency_key)
            )
            """), down: SQLQuery(unsafeSQL: "DROP TABLE IF EXISTS \(posts)")),
        SQLMigration(id: "social-content-v1-02-post-feed-index", up: SQLQuery(unsafeSQL: """
            CREATE INDEX IF NOT EXISTS pearfy_social_posts_feed_idx
                ON \(posts) (created_at DESC, id DESC) WHERE deleted_at IS NULL
            """), down: SQLQuery(unsafeSQL: "DROP INDEX IF EXISTS pearfy_social_posts_feed_idx")),
        SQLMigration(id: "social-content-v1-03-comments", up: SQLQuery(unsafeSQL: """
            CREATE TABLE IF NOT EXISTS \(comments) (
                id UUID PRIMARY KEY,
                post_id UUID NOT NULL REFERENCES \(posts)(id) ON DELETE CASCADE,
                parent_comment_id UUID REFERENCES \(comments)(id) ON DELETE CASCADE,
                actor_id UUID NOT NULL REFERENCES \(actors)(id) ON DELETE CASCADE,
                owner_id UUID NOT NULL,
                body TEXT NOT NULL CHECK (length(trim(body)) BETWEEN 1 AND 2000),
                moderation_status TEXT NOT NULL DEFAULT 'pending' CHECK (moderation_status IN ('pending','approved','rejected','error')),
                moderation_revision BIGINT NOT NULL DEFAULT 1 CHECK (moderation_revision > 0),
                content_digest TEXT NOT NULL,
                idempotency_key TEXT NOT NULL,
                moderation_reason TEXT,
                moderation_checked_at TIMESTAMPTZ,
                created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                deleted_at TIMESTAMPTZ,
                UNIQUE (owner_id, idempotency_key)
            )
            """), down: SQLQuery(unsafeSQL: "DROP TABLE IF EXISTS \(comments)")),
        SQLMigration(id: "social-content-v1-04-comment-index", up: SQLQuery(unsafeSQL: """
            CREATE INDEX IF NOT EXISTS pearfy_social_comments_post_idx
                ON \(comments) (post_id, created_at, id) WHERE deleted_at IS NULL
            """), down: SQLQuery(unsafeSQL: "DROP INDEX IF EXISTS pearfy_social_comments_post_idx")),
        SQLMigration(id: "social-content-v1-05-reactions", up: SQLQuery(unsafeSQL: """
            CREATE TABLE IF NOT EXISTS \(reactions) (
                post_id UUID NOT NULL REFERENCES \(posts)(id) ON DELETE CASCADE,
                actor_id UUID NOT NULL REFERENCES \(actors)(id) ON DELETE CASCADE,
                owner_id UUID NOT NULL,
                kind TEXT NOT NULL CHECK (length(kind) BETWEEN 1 AND 32),
                created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (post_id, actor_id, kind)
            )
            """), down: SQLQuery(unsafeSQL: "DROP TABLE IF EXISTS \(reactions)")),
        SQLMigration(id: "social-content-v1-06-moderation-queue", up: SQLQuery(unsafeSQL: """
            CREATE TABLE IF NOT EXISTS \(moderationQueue) (
                id UUID PRIMARY KEY,
                content_kind TEXT NOT NULL CHECK (content_kind IN ('post','comment')),
                content_id UUID NOT NULL,
                owner_id UUID NOT NULL,
                content TEXT NOT NULL,
                digest TEXT NOT NULL,
                revision BIGINT NOT NULL CHECK (revision > 0),
                attempts INT NOT NULL DEFAULT 0,
                next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                claimed_at TIMESTAMPTZ,
                claimed_by UUID,
                claim_token UUID,
                completed_at TIMESTAMPTZ,
                last_error TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                UNIQUE (content_kind, content_id, digest, revision)
            )
            """), down: SQLQuery(unsafeSQL: "DROP TABLE IF EXISTS \(moderationQueue)")),
        SQLMigration(id: "social-content-v1-07-moderation-index", up: SQLQuery(unsafeSQL: """
            CREATE INDEX IF NOT EXISTS pearfy_social_moderation_claim_idx
                ON \(moderationQueue) (next_attempt_at, created_at, id) WHERE completed_at IS NULL
            """), down: SQLQuery(unsafeSQL: "DROP INDEX IF EXISTS pearfy_social_moderation_claim_idx")),
        SQLMigration(id: "social-content-v1-08-moderation-audit", up: SQLQuery(unsafeSQL: """
            CREATE TABLE IF NOT EXISTS \(moderationAudit) (
                id UUID PRIMARY KEY,
                queue_id UUID NOT NULL REFERENCES \(moderationQueue)(id) ON DELETE CASCADE,
                content_kind TEXT NOT NULL,
                content_id UUID NOT NULL,
                provider TEXT NOT NULL,
                result TEXT NOT NULL CHECK (result IN ('approved','rejected')),
                reason TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                UNIQUE (queue_id)
            )
            """), down: SQLQuery(unsafeSQL: "DROP TABLE IF EXISTS \(moderationAudit)")),
        SQLMigration(id: "social-content-v1-09-notifications", up: SQLQuery(unsafeSQL: """
            CREATE TABLE IF NOT EXISTS \(notifications) (
                id UUID PRIMARY KEY,
                recipient_owner_id UUID NOT NULL,
                actor_owner_id UUID NOT NULL,
                notification_kind TEXT NOT NULL CHECK (notification_kind IN ('follow','comment','reaction','mention','share')),
                entity_kind TEXT NOT NULL CHECK (entity_kind IN ('actor','post','comment','community')),
                entity_id UUID NOT NULL,
                idempotency_key TEXT NOT NULL UNIQUE,
                created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                read_at TIMESTAMPTZ
            )
            """), down: SQLQuery(unsafeSQL: "DROP TABLE IF EXISTS \(notifications)")),
        SQLMigration(id: "social-content-v1-10-notification-index", up: SQLQuery(unsafeSQL: """
            CREATE INDEX IF NOT EXISTS pearfy_social_notifications_owner_idx
                ON \(notifications) (recipient_owner_id, created_at DESC, id DESC)
            """), down: SQLQuery(unsafeSQL: "DROP INDEX IF EXISTS pearfy_social_notifications_owner_idx"))
    ]
}

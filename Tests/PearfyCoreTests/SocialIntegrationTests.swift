import Foundation
import PearfyData
import PearfyPostgres
import PearfySocial
import PearfySocialPostgres
import PostgresNIO
import Testing

@Test func postgresSocialGraphEnforcesOwnerVisibilityFollowAndBlockPolicies() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PORT"] ?? "5432") ?? 5432
    let username = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_USER"] ?? "postgres"
    let databaseName = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_DATABASE"] ?? username
    let password = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PASSWORD"]
    var configuration = PostgresClient.Configuration(
        host: host,
        port: port,
        username: username,
        password: password,
        database: databaseName,
        tls: .disable
    )
    configuration.options.maximumConnections = 1
    configuration.options.minimumConnections = 0

    let database = PearfyPostgresDatabase(configuration: configuration)
    try await database.start()
    let graph = PostgresSocialGraphStore(database: database)
    let suffix = UUIDv7.generate().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let ownerA = UUIDv7.generate()
    let ownerB = UUIDv7.generate()
    let ownerC = UUIDv7.generate()
    let alice = try SocialActor(ownerID: ownerA, kind: .person, handle: "alice-\(suffix)")
    let bob = try SocialActor(ownerID: ownerB, kind: .person, handle: "bob-\(suffix)", visibility: .followers)
    let carol = try SocialActor(ownerID: ownerC, kind: .page, handle: "carol-\(suffix)")
    let invalidActorID = UUIDv7.generate()

    do {
        try await graph.installSchema()
        try await graph.installSchema()

        var invalidPersistedHandleRejected = false
        do {
            try await database.execute(SQLQuery(
                unsafeSQL: """
                INSERT INTO "pearfy_social_actors" (id, owner_id, actor_kind, handle, visibility)
                VALUES ($1, $2, 'person', $3, 'public')
                """,
                parameters: [.uuid(invalidActorID), .uuid(ownerA), .text("Invalid-\(suffix)")]
            ))
        } catch {
            invalidPersistedHandleRejected = true
        }
        #expect(invalidPersistedHandleRejected)

        try await graph.createActor(alice)
        try await graph.createActor(alice)
        try await graph.createActor(bob)
        try await graph.createActor(carol)

        let conflictingAlice = try SocialActor(
            id: alice.id,
            ownerID: ownerA,
            kind: .person,
            handle: "changed-\(suffix)"
        )
        var conflictingActorRejected = false
        do {
            try await graph.createActor(conflictingAlice)
        } catch SocialGraphError.actorIdentityConflict {
            conflictingActorRejected = true
        }
        #expect(conflictingActorRejected)

        #expect(try await graph.follow(ownerID: ownerA, sourceActorID: alice.id, targetActorID: bob.id) == .pending)
        #expect(try await graph.canView(viewerOwnerID: ownerA, targetActorID: bob.id) == false)
        try await graph.approveFollow(ownerID: ownerB, sourceActorID: alice.id, targetActorID: bob.id)
        #expect(try await graph.canView(viewerOwnerID: ownerA, targetActorID: bob.id))

        try await graph.block(ownerID: ownerB, blockerActorID: bob.id, blockedActorID: alice.id)
        #expect(try await graph.canView(viewerOwnerID: ownerA, targetActorID: bob.id) == false)
        var blockedFollowRejected = false
        do {
            _ = try await graph.follow(ownerID: ownerA, sourceActorID: alice.id, targetActorID: bob.id)
        } catch SocialGraphError.blocked {
            blockedFollowRejected = true
        }
        #expect(blockedFollowRejected)
        try await graph.unblock(ownerID: ownerB, blockerActorID: bob.id, blockedActorID: alice.id)
        #expect(try await graph.canView(viewerOwnerID: ownerA, targetActorID: bob.id) == false)

        #expect(try await graph.follow(ownerID: ownerA, sourceActorID: alice.id, targetActorID: carol.id) == .accepted)
        #expect(try await graph.follow(ownerID: ownerA, sourceActorID: alice.id, targetActorID: carol.id) == .accepted)
        #expect(try await graph.canView(viewerOwnerID: nil, targetActorID: carol.id))

        var wrongOwnerRejected = false
        do {
            _ = try await graph.follow(ownerID: ownerB, sourceActorID: alice.id, targetActorID: carol.id)
        } catch SocialGraphError.actorOwnershipRequired {
            wrongOwnerRejected = true
        }
        #expect(wrongOwnerRejected)

        try await database.execute(SQLQuery(
            unsafeSQL: "DELETE FROM \"pearfy_social_actors\" WHERE id = $1 OR id = $2 OR id = $3 OR id = $4",
            parameters: [.uuid(alice.id), .uuid(bob.id), .uuid(carol.id), .uuid(invalidActorID)]
        ))
    } catch {
        try? await database.execute(SQLQuery(
            unsafeSQL: "DELETE FROM \"pearfy_social_actors\" WHERE id = $1 OR id = $2 OR id = $3 OR id = $4",
            parameters: [.uuid(alice.id), .uuid(bob.id), .uuid(carol.id), .uuid(invalidActorID)]
        ))
        try? await database.stop()
        throw error
    }
    try await database.stop()
}

@Test func postgresSocialContentIsIdempotentPrivateModeratedAndCrossReplicaClaimed() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PORT"] ?? "5432") ?? 5432
    let username = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_USER"] ?? "postgres"
    let databaseName = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_DATABASE"] ?? username
    let password = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PASSWORD"]
    var configuration = PostgresClient.Configuration(
        host: host,
        port: port,
        username: username,
        password: password,
        database: databaseName,
        tls: .disable
    )
    configuration.options.maximumConnections = 4
    configuration.options.minimumConnections = 0

    let databaseA = PearfyPostgresDatabase(configuration: configuration)
    let databaseB = PearfyPostgresDatabase(configuration: configuration)
    try await databaseA.start()
    try await databaseB.start()
    let graph = PostgresSocialGraphStore(database: databaseA)
    let storeA = PostgresSocialContentStore(database: databaseA)
    let storeB = PostgresSocialContentStore(database: databaseB)
    let suffix = UUIDv7.generate().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let ownerA = UUIDv7.generate()
    let ownerB = UUIDv7.generate()
    let ownerPrivate = UUIDv7.generate()
    let actorA = try SocialActor(ownerID: ownerA, kind: .person, handle: "content-author-\(suffix)")
    let actorB = try SocialActor(ownerID: ownerB, kind: .person, handle: "content-commenter-\(suffix)")
    let privateActor = try SocialActor(
        ownerID: ownerPrivate,
        kind: .person,
        handle: "content-private-\(suffix)",
        visibility: .private
    )

    do {
        try await storeA.installSchema()
        try await storeA.installSchema()
        try await graph.createActor(actorA)
        try await graph.createActor(actorB)
        try await graph.createActor(privateActor)

        let postDraft = try SocialPostDraft(
            actorID: actorA.id,
            ownerID: ownerA,
            body: "An idempotent social post",
            idempotencyKey: "post-\(suffix)"
        )
        let post = try await storeA.publish(postDraft)
        #expect(post.moderationStatus == .pending)
        #expect(try await storeA.publish(postDraft).id == post.id)
        #expect(try await storeA.feed(SocialFeedRequest(viewerOwnerID: nil)).items.isEmpty)
        #expect(try await storeA.feed(SocialFeedRequest(viewerOwnerID: ownerA)).items.map(\.id) == [post.id])

        let conflictingDraft = try SocialPostDraft(
            actorID: actorA.id,
            ownerID: ownerA,
            body: "Different payload",
            idempotencyKey: postDraft.idempotencyKey
        )
        var keyConflictObserved = false
        do {
            _ = try await storeA.publish(conflictingDraft)
        } catch SocialContentError.idempotencyKeyConflict {
            keyConflictObserved = true
        }
        #expect(keyConflictObserved)

        let claims = try await withThrowingTaskGroup(of: SocialModerationWorkItem?.self) { group in
            group.addTask {
                try await storeA.claimModeration(
                    workerID: UUIDv7.generate(), leaseDuration: .seconds(60), maximumAttempts: 3
                )
            }
            group.addTask {
                try await storeB.claimModeration(
                    workerID: UUIDv7.generate(), leaseDuration: .seconds(60), maximumAttempts: 3
                )
            }
            var values: [SocialModerationWorkItem?] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(claims.compactMap { $0 }.count == 1)
        guard let postWork = claims.compactMap({ $0 }).first else { throw SocialContentIntegrationFailure.missingClaim }
        #expect(postWork.contentID == post.id)
        #expect(try await storeA.completeModeration(postWork, decision: .init(result: .approved)))
        #expect(try await storeA.feed(SocialFeedRequest(viewerOwnerID: nil)).items.map(\.id) == [post.id])

        let commentDraft = try SocialCommentDraft(
            postID: post.id,
            actorID: actorB.id,
            ownerID: ownerB,
            body: "A reviewed comment",
            idempotencyKey: "comment-\(suffix)"
        )
        let comment = try await storeA.comment(commentDraft)
        #expect(comment.moderationStatus == .pending)
        let notificationsBeforeApproval = try await storeA.notifications(
            SocialNotificationRequest(ownerID: ownerA)
        )
        #expect(notificationsBeforeApproval.items.isEmpty)
        let commentWork = try await storeA.claimModeration(
            workerID: UUIDv7.generate(), leaseDuration: .seconds(60), maximumAttempts: 3
        )
        #expect(commentWork?.contentID == comment.id)
        guard let commentWork else { throw SocialContentIntegrationFailure.missingClaim }
        #expect(try await storeA.completeModeration(commentWork, decision: .init(result: .approved)))
        #expect(try await storeA.comments(SocialCommentRequest(postID: post.id, viewerOwnerID: nil)).items.map(\.id) == [comment.id])

        #expect(try await graph.follow(ownerID: ownerB, sourceActorID: actorB.id, targetActorID: actorA.id) == .accepted)
        #expect(try await storeA.feed(SocialFeedRequest(
            viewerOwnerID: ownerB,
            scope: .following
        )).items.map(\.id) == [post.id])

        let reaction = try SocialReaction(postID: post.id, actorID: actorB.id, ownerID: ownerB, kind: "heart")
        #expect(try await storeA.setReaction(reaction))
        #expect(try await storeA.setReaction(reaction) == false)
        #expect(try await storeA.removeReaction(reaction))
        let deliveredNotifications = try await storeA.notifications(SocialNotificationRequest(ownerID: ownerA))
        #expect(deliveredNotifications.items.count == 2)
        #expect(deliveredNotifications.items.contains(where: { $0.kind == .comment }))
        #expect(deliveredNotifications.items.contains(where: { $0.kind == .reaction }))

        try await graph.block(ownerID: ownerA, blockerActorID: actorA.id, blockedActorID: actorB.id)
        #expect(try await storeA.feed(SocialFeedRequest(viewerOwnerID: ownerB)).items.isEmpty)
        try await graph.unblock(ownerID: ownerA, blockerActorID: actorA.id, blockedActorID: actorB.id)

        let terminalDraft = try SocialPostDraft(
            actorID: actorA.id,
            ownerID: ownerA,
            body: "Provider retry exhausted",
            idempotencyKey: "terminal-\(suffix)"
        )
        let terminalPost = try await storeA.publish(terminalDraft)
        let terminalWork = try await storeA.claimModeration(
            workerID: UUIDv7.generate(), leaseDuration: .seconds(60), maximumAttempts: 1
        )
        #expect(terminalWork?.contentID == terminalPost.id)
        guard let terminalWork else { throw SocialContentIntegrationFailure.missingClaim }
        try await storeA.retryModeration(terminalWork, errorCode: "ProviderUnavailable", maximumAttempts: 1)
        #expect(try await storeA.claimModeration(
            workerID: UUIDv7.generate(), leaseDuration: .seconds(60), maximumAttempts: 1
        ) == nil)
        let ownerPosts = try await storeA.feed(SocialFeedRequest(viewerOwnerID: ownerA))
        #expect(ownerPosts.items.first(where: { $0.id == terminalPost.id })?.moderationStatus == .review)

        let privateDraft = try SocialPostDraft(
            actorID: privateActor.id,
            ownerID: ownerPrivate,
            body: "Private content",
            visibility: .public,
            idempotencyKey: "private-\(suffix)"
        )
        let privatePost = try await storeA.publish(privateDraft)
        let privateWork = try await storeA.claimModeration(
            workerID: UUIDv7.generate(), leaseDuration: .seconds(60), maximumAttempts: 3
        )
        #expect(privateWork?.contentID == privatePost.id)
        guard let privateWork else { throw SocialContentIntegrationFailure.missingClaim }
        #expect(try await storeA.completeModeration(privateWork, decision: .init(result: .approved)))
        #expect(try await storeA.feed(SocialFeedRequest(viewerOwnerID: ownerB)).items.map(\.id) == [post.id])
        #expect(try await storeA.feed(SocialFeedRequest(viewerOwnerID: ownerPrivate)).items.map(\.id).contains(privatePost.id))

        try await databaseA.execute(SQLQuery(
            unsafeSQL: "DELETE FROM \"pearfy_social_moderation_queue\" WHERE owner_id = ANY($1::UUID[])",
            parameters: [.text("{\(ownerA.uuidString),\(ownerB.uuidString),\(ownerPrivate.uuidString)}")]
        ))
        try await databaseA.execute(SQLQuery(
            unsafeSQL: "DELETE FROM \"pearfy_social_notifications\" WHERE recipient_owner_id = ANY($1::UUID[]) OR actor_owner_id = ANY($1::UUID[])",
            parameters: [.text("{\(ownerA.uuidString),\(ownerB.uuidString),\(ownerPrivate.uuidString)}")]
        ))
        try await databaseA.execute(SQLQuery(
            unsafeSQL: "DELETE FROM \"pearfy_social_actors\" WHERE id = ANY($1::UUID[])",
            parameters: [.text("{\(actorA.id.uuidString),\(actorB.id.uuidString),\(privateActor.id.uuidString)}")]
        ))
    } catch {
        try? await databaseA.execute(SQLQuery(
            unsafeSQL: "DELETE FROM \"pearfy_social_moderation_queue\" WHERE owner_id = ANY($1::UUID[])",
            parameters: [.text("{\(ownerA.uuidString),\(ownerB.uuidString),\(ownerPrivate.uuidString)}")]
        ))
        try? await databaseA.execute(SQLQuery(
            unsafeSQL: "DELETE FROM \"pearfy_social_notifications\" WHERE recipient_owner_id = ANY($1::UUID[]) OR actor_owner_id = ANY($1::UUID[])",
            parameters: [.text("{\(ownerA.uuidString),\(ownerB.uuidString),\(ownerPrivate.uuidString)}")]
        ))
        try? await databaseA.execute(SQLQuery(
            unsafeSQL: "DELETE FROM \"pearfy_social_actors\" WHERE id = ANY($1::UUID[])",
            parameters: [.text("{\(actorA.id.uuidString),\(actorB.id.uuidString),\(privateActor.id.uuidString)}")]
        ))
        try? await databaseA.stop()
        try? await databaseB.stop()
        throw error
    }
    try await databaseA.stop()
    try await databaseB.stop()
}

private enum SocialContentIntegrationFailure: Error {
    case missingClaim
}

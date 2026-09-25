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
        try await graph.createActor(bob)
        try await graph.createActor(carol)

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

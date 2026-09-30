import Foundation
import PearfyData
import PearfySocial
import Testing

@Test func socialPostDraftPreservesExistingOwnerAndCreatesPendingContent() throws {
    let existingUserID = UUID(uuidString: "30000000-0000-7000-8000-000000000001")!
    let actorID = UUIDv7.generate()
    let draft = try SocialPostDraft(
        actorID: actorID,
        ownerID: existingUserID,
        body: "  Playing tonight  ",
        idempotencyKey: "request-42"
    )
    let post = try SocialPost(
        id: draft.id,
        actorID: draft.actorID,
        ownerID: draft.ownerID,
        body: draft.body,
        visibility: draft.visibility,
        createdAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: Date(timeIntervalSince1970: 1_000)
    )

    #expect(post.ownerID == existingUserID)
    #expect(post.actorID == actorID)
    #expect(post.body == "Playing tonight")
    #expect(post.moderationStatus == .pending)
    #expect(post.moderationRevision == 1)
    #expect(UUIDv7.timestampMilliseconds(from: draft.id) != nil)
}

@Test func socialCommentDraftKeepsParentAndValidatesBodyBounds() throws {
    let postID = UUIDv7.generate()
    let parentID = UUIDv7.generate()
    let draft = try SocialCommentDraft(
        postID: postID,
        parentCommentID: parentID,
        actorID: UUIDv7.generate(),
        ownerID: UUIDv7.generate(),
        body: "  Good game  ",
        idempotencyKey: "comment-42"
    )
    #expect(draft.postID == postID)
    #expect(draft.parentCommentID == parentID)
    #expect(draft.body == "Good game")

    #expect(throws: SocialContentError.invalidBody) {
        try SocialCommentDraft(
            postID: postID,
            actorID: UUIDv7.generate(),
            ownerID: UUIDv7.generate(),
            body: " \n ",
            idempotencyKey: "comment-empty"
        )
    }
}

@Test func socialContentDraftRejectsUnsafeIdempotencyKeysAndInvalidReactionKinds() throws {
    #expect(throws: SocialContentError.invalidIdempotencyKey) {
        try SocialPostDraft(
            actorID: UUIDv7.generate(),
            ownerID: UUIDv7.generate(),
            body: "Post",
            idempotencyKey: "invalid\nkey"
        )
    }

    #expect(throws: SocialContentError.invalidReaction) {
        try SocialReaction(
            postID: UUIDv7.generate(),
            actorID: UUIDv7.generate(),
            ownerID: UUIDv7.generate(),
            kind: "👍"
        )
    }
    #expect(try SocialReaction(
        postID: UUIDv7.generate(),
        actorID: UUIDv7.generate(),
        ownerID: UUIDv7.generate(),
        kind: "heart"
    ).kind == "heart")
}

@Test func socialFeedCursorIsStableAndLimitIsBoundedByContract() throws {
    let cursor = SocialFeedCursor(createdAt: Date(timeIntervalSince1970: 1_700_000_000), id: UUIDv7.generate())
    let request = try SocialFeedRequest(viewerOwnerID: UUIDv7.generate(), cursor: cursor, limit: 100)
    #expect(request.cursor == cursor)
    #expect(request.limit == 100)
    #expect(throws: SocialContentError.invalidPageLimit) {
        try SocialFeedRequest(viewerOwnerID: nil, limit: 101)
    }
}

@Test func socialModerationWorkItemBindsRevisionDigestAndClaim() throws {
    let id = UUIDv7.generate()
    let contentID = UUIDv7.generate()
    let claimToken = UUIDv7.generate()
    let work = try SocialModerationWorkItem(
        id: id,
        kind: .post,
        contentID: contentID,
        ownerID: UUIDv7.generate(),
        body: "generic social content",
        digest: String(repeating: "a", count: 64),
        revision: 2,
        attempt: 0,
        claimToken: claimToken
    )
    #expect(work.revision == 2)
    #expect(work.attempt == 1)
    #expect(work.claimToken == claimToken)

    #expect(throws: SocialContentError.invalidModerationDigest) {
        try SocialModerationWorkItem(
            id: id,
            kind: .post,
            contentID: contentID,
            ownerID: UUIDv7.generate(),
            body: "generic social content",
            digest: "not-a-digest",
            revision: 2,
            attempt: 1,
            claimToken: claimToken
        )
    }
}

@Test func moderationWorkerCompletesClaimedWorkAndRetriesOnlyProviderFailures() async throws {
    let item = try SocialModerationWorkItem(
        id: UUIDv7.generate(),
        kind: .post,
        contentID: UUIDv7.generate(),
        ownerID: UUIDv7.generate(),
        body: "safe generic post",
        digest: String(repeating: "b", count: 64),
        revision: 1,
        attempt: 1,
        claimToken: UUIDv7.generate()
    )
    let store = TestSocialContentStore(item: item)
    let provider = TestSocialModerationProvider(result: .approved)
    let worker = try SocialModerationWorker(store: store, provider: provider)

    #expect(try await worker.runOnce())
    #expect(await store.completedDecision == SocialModerationDecision(result: .approved))
    #expect(await store.retryErrorCode == nil)
    #expect(await provider.callCount == 1)
}

@Test func moderationWorkerPersistsProviderFailureWithoutForwardingErrorDetails() async throws {
    let item = try makeWorkItem()
    let store = TestSocialContentStore(item: item)
    let provider = TestSocialModerationProvider(result: nil, fails: true)
    let worker = try SocialModerationWorker(store: store, provider: provider)

    #expect(try await worker.runOnce())
    #expect(await store.retryErrorCode?.hasSuffix("TestProviderError") == true)
    #expect(await store.completedDecision == nil)
    #expect(await provider.callCount == 1)
}

@Test func moderationWorkerDoesNotRetryWhenTheDecisionCommitFails() async throws {
    let item = try makeWorkItem()
    let store = TestSocialContentStore(item: item, failCompletion: true)
    let provider = TestSocialModerationProvider(result: .approved)
    let worker = try SocialModerationWorker(store: store, provider: provider)
    var commitFailurePropagated = false

    do {
        _ = try await worker.runOnce()
    } catch TestStoreError.unknownCommit {
        commitFailurePropagated = true
    }

    #expect(commitFailurePropagated)
    #expect(await store.retryErrorCode == nil)
    #expect(await provider.callCount == 1)
}

@Test func socialNotificationRequiresAnIdempotencyKey() throws {
    let recipientID = UUIDv7.generate()
    let note = try SocialNotification(
        id: UUIDv7.generate(),
        recipientOwnerID: recipientID,
        actorOwnerID: UUIDv7.generate(),
        kind: .comment,
        entityKind: .post,
        entityID: UUIDv7.generate(),
        idempotencyKey: "comment:recipient:actor:entity",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(note.recipientOwnerID == recipientID)

    #expect(throws: SocialContentError.invalidIdempotencyKey) {
        try SocialNotification(
            id: UUIDv7.generate(),
            recipientOwnerID: recipientID,
            actorOwnerID: UUIDv7.generate(),
            kind: .comment,
            entityKind: .post,
            entityID: UUIDv7.generate(),
            idempotencyKey: "\n",
            createdAt: Date()
        )
    }
}

private actor TestSocialContentStore: SocialContentStore {
    let item: SocialModerationWorkItem
    private let failCompletion: Bool
    var claimed = false
    private(set) var completedDecision: SocialModerationDecision?
    private(set) var retryErrorCode: String?

    init(item: SocialModerationWorkItem, failCompletion: Bool = false) {
        self.item = item
        self.failCompletion = failCompletion
    }

    func installSchema() async throws {}
    func publish(_ draft: SocialPostDraft) async throws -> SocialPost { throw TestStoreError.unused }
    func comment(_ draft: SocialCommentDraft) async throws -> SocialComment { throw TestStoreError.unused }
    func setReaction(_ reaction: SocialReaction) async throws -> Bool { throw TestStoreError.unused }
    func removeReaction(_ reaction: SocialReaction) async throws -> Bool { throw TestStoreError.unused }
    func feed(_ request: SocialFeedRequest) async throws -> SocialFeedPage { throw TestStoreError.unused }
    func comments(_ request: SocialCommentRequest) async throws -> SocialCommentPage { throw TestStoreError.unused }
    func notifications(_ request: SocialNotificationRequest) async throws -> SocialNotificationPage { throw TestStoreError.unused }

    func claimModeration(workerID: UUID, leaseDuration: Duration, maximumAttempts: Int) async throws -> SocialModerationWorkItem? {
        guard !claimed else { return nil }
        claimed = true
        return item
    }

    func completeModeration(_ item: SocialModerationWorkItem, decision: SocialModerationDecision) async throws -> Bool {
        if failCompletion { throw TestStoreError.unknownCommit }
        completedDecision = decision
        return true
    }

    func retryModeration(_ item: SocialModerationWorkItem, errorCode: String, maximumAttempts: Int) async throws {
        retryErrorCode = errorCode
    }
}

private struct TestSocialModerationProvider: SocialModerationProvider {
    let result: SocialModerationResult?
    let fails: Bool
    private let count = TestCallCounter()

    init(result: SocialModerationResult, fails: Bool = false) {
        self.result = result
        self.fails = fails
    }

    init(result: SocialModerationResult?, fails: Bool) {
        self.result = result
        self.fails = fails
    }

    var callCount: Int { get async { await count.value } }

    func moderate(_ workItem: SocialModerationWorkItem) async throws -> SocialModerationDecision {
        await count.increment()
        if fails { throw TestProviderError.unavailable }
        return SocialModerationDecision(result: result ?? .rejected)
    }
}

private actor TestCallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private enum TestStoreError: Error {
    case unused
    case unknownCommit
}

private enum TestProviderError: Error {
    case unavailable
}

private func makeWorkItem() throws -> SocialModerationWorkItem {
    try SocialModerationWorkItem(
        id: UUIDv7.generate(),
        kind: .post,
        contentID: UUIDv7.generate(),
        ownerID: UUIDv7.generate(),
        body: "safe generic post",
        digest: String(repeating: "c", count: 64),
        revision: 1,
        attempt: 1,
        claimToken: UUIDv7.generate()
    )
}

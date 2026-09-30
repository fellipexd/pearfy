import Foundation
import PearfyData

public enum SocialContentStatus: String, Codable, Sendable {
    case pending
    case approved
    case rejected
    case error
}

public enum SocialContentKind: String, Codable, Sendable {
    case post
    case comment
}

public enum SocialContentError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidBody
    case invalidIdempotencyKey
    case invalidReaction
    case invalidPageLimit
    case invalidModerationRevision
    case invalidModerationDigest
    case idempotencyKeyConflict
    case postNotFoundOrNotVisible
    case commentParentNotFound
    case ownPostReaction

    public var description: String {
        switch self {
        case .invalidBody: "PEARFY_SOCIAL_007: content body must contain 1...5000 characters"
        case .invalidIdempotencyKey: "PEARFY_SOCIAL_008: idempotency key must contain 1...200 safe characters"
        case .invalidReaction: "PEARFY_SOCIAL_009: reaction must be a lowercase identifier"
        case .invalidPageLimit: "PEARFY_SOCIAL_010: page limit must be in 1...100"
        case .invalidModerationRevision: "PEARFY_SOCIAL_011: moderation revision must be positive"
        case .invalidModerationDigest: "PEARFY_SOCIAL_012: moderation digest must be a SHA-256 hex value"
        case .idempotencyKeyConflict: "PEARFY_SOCIAL_014: idempotency key was reused with a different request payload"
        case .postNotFoundOrNotVisible: "PEARFY_SOCIAL_015: post was not found or is not visible"
        case .commentParentNotFound: "PEARFY_SOCIAL_016: parent comment was not found in this post"
        case .ownPostReaction: "PEARFY_SOCIAL_017: an owner cannot react to their own post"
        }
    }
}

/// A generic social post. `ownerID` is the application's existing identity;
/// PearfySocial does not create, merge, or replace authentication accounts.
public struct SocialPost: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let actorID: UUID
    public let ownerID: UUID
    public let body: String
    public let visibility: SocialVisibility
    public let moderationStatus: SocialContentStatus
    public let moderationRevision: Int64
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        actorID: UUID,
        ownerID: UUID,
        body: String,
        visibility: SocialVisibility,
        moderationStatus: SocialContentStatus = .pending,
        moderationRevision: Int64 = 1,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...5000).contains(normalizedBody.count) else { throw SocialContentError.invalidBody }
        guard moderationRevision > 0 else { throw SocialContentError.invalidModerationRevision }
        self.id = id
        self.actorID = actorID
        self.ownerID = ownerID
        self.body = normalizedBody
        self.visibility = visibility
        self.moderationStatus = moderationStatus
        self.moderationRevision = moderationRevision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// An application-neutral write request. The idempotency key is persisted by
/// the store so retrying an HTTP request cannot create a second post.
public struct SocialPostDraft: Sendable, Equatable {
    public let id: UUID
    public let actorID: UUID
    public let ownerID: UUID
    public let body: String
    public let visibility: SocialVisibility
    public let idempotencyKey: String

    public init(
        id: UUID = UUIDv7.generate(),
        actorID: UUID,
        ownerID: UUID,
        body: String,
        visibility: SocialVisibility = .public,
        idempotencyKey: String
    ) throws {
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...5000).contains(normalizedBody.count) else { throw SocialContentError.invalidBody }
        try validateIdempotencyKey(idempotencyKey)
        self.id = id
        self.actorID = actorID
        self.ownerID = ownerID
        self.body = normalizedBody
        self.visibility = visibility
        self.idempotencyKey = idempotencyKey
    }
}

public struct SocialComment: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let postID: UUID
    public let parentCommentID: UUID?
    public let actorID: UUID
    public let ownerID: UUID
    public let body: String
    public let moderationStatus: SocialContentStatus
    public let moderationRevision: Int64
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        postID: UUID,
        parentCommentID: UUID? = nil,
        actorID: UUID,
        ownerID: UUID,
        body: String,
        moderationStatus: SocialContentStatus = .pending,
        moderationRevision: Int64 = 1,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(normalizedBody.count) else { throw SocialContentError.invalidBody }
        guard moderationRevision > 0 else { throw SocialContentError.invalidModerationRevision }
        self.id = id
        self.postID = postID
        self.parentCommentID = parentCommentID
        self.actorID = actorID
        self.ownerID = ownerID
        self.body = normalizedBody
        self.moderationStatus = moderationStatus
        self.moderationRevision = moderationRevision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SocialCommentDraft: Sendable, Equatable {
    public let id: UUID
    public let postID: UUID
    public let parentCommentID: UUID?
    public let actorID: UUID
    public let ownerID: UUID
    public let body: String
    public let idempotencyKey: String

    public init(
        id: UUID = UUIDv7.generate(),
        postID: UUID,
        parentCommentID: UUID? = nil,
        actorID: UUID,
        ownerID: UUID,
        body: String,
        idempotencyKey: String
    ) throws {
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(normalizedBody.count) else { throw SocialContentError.invalidBody }
        try validateIdempotencyKey(idempotencyKey)
        self.id = id
        self.postID = postID
        self.parentCommentID = parentCommentID
        self.actorID = actorID
        self.ownerID = ownerID
        self.body = normalizedBody
        self.idempotencyKey = idempotencyKey
    }
}

public struct SocialReaction: Sendable, Equatable {
    public let postID: UUID
    public let actorID: UUID
    public let ownerID: UUID
    public let kind: String

    public init(postID: UUID, actorID: UUID, ownerID: UUID, kind: String) throws {
        guard Self.isValidKind(kind) else { throw SocialContentError.invalidReaction }
        self.postID = postID
        self.actorID = actorID
        self.ownerID = ownerID
        self.kind = kind
    }

    private static func isValidKind(_ value: String) -> Bool {
        (1...32).contains(value.utf8.count) && value.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

public struct SocialFeedCursor: Codable, Equatable, Sendable {
    public let createdAt: Date
    public let id: UUID

    public init(createdAt: Date, id: UUID) {
        self.createdAt = createdAt
        self.id = id
    }
}

public enum SocialFeedScope: String, Codable, Sendable {
    case global
    case following
}

public struct SocialFeedRequest: Sendable, Equatable {
    public let viewerOwnerID: UUID?
    public let cursor: SocialFeedCursor?
    public let limit: Int
    public let scope: SocialFeedScope

    public init(
        viewerOwnerID: UUID?,
        cursor: SocialFeedCursor? = nil,
        limit: Int = 20,
        scope: SocialFeedScope = .global
    ) throws {
        guard (1...100).contains(limit) else { throw SocialContentError.invalidPageLimit }
        self.viewerOwnerID = viewerOwnerID
        self.cursor = cursor
        self.limit = limit
        self.scope = scope
    }
}

public struct SocialFeedPage: Codable, Equatable, Sendable {
    public let items: [SocialPost]
    public let nextCursor: SocialFeedCursor?

    public init(items: [SocialPost], nextCursor: SocialFeedCursor? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct SocialCommentRequest: Sendable, Equatable {
    public let postID: UUID
    public let viewerOwnerID: UUID?
    public let cursor: SocialFeedCursor?
    public let limit: Int

    public init(postID: UUID, viewerOwnerID: UUID?, cursor: SocialFeedCursor? = nil, limit: Int = 20) throws {
        guard (1...100).contains(limit) else { throw SocialContentError.invalidPageLimit }
        self.postID = postID
        self.viewerOwnerID = viewerOwnerID
        self.cursor = cursor
        self.limit = limit
    }
}

public struct SocialCommentPage: Codable, Equatable, Sendable {
    public let items: [SocialComment]
    public let nextCursor: SocialFeedCursor?

    public init(items: [SocialComment], nextCursor: SocialFeedCursor? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public enum SocialNotificationKind: String, Codable, Sendable {
    case follow
    case comment
    case reaction
    case mention
    case share
}

public enum SocialNotificationEntityKind: String, Codable, Sendable {
    case actor
    case post
    case comment
    case community
}

public struct SocialNotification: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let recipientOwnerID: UUID
    public let actorOwnerID: UUID
    public let kind: SocialNotificationKind
    public let entityKind: SocialNotificationEntityKind
    public let entityID: UUID
    public let idempotencyKey: String
    public let createdAt: Date

    public init(
        id: UUID,
        recipientOwnerID: UUID,
        actorOwnerID: UUID,
        kind: SocialNotificationKind,
        entityKind: SocialNotificationEntityKind,
        entityID: UUID,
        idempotencyKey: String,
        createdAt: Date
    ) throws {
        try validateIdempotencyKey(idempotencyKey)
        self.id = id
        self.recipientOwnerID = recipientOwnerID
        self.actorOwnerID = actorOwnerID
        self.kind = kind
        self.entityKind = entityKind
        self.entityID = entityID
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
    }
}

public struct SocialNotificationRequest: Sendable, Equatable {
    public let ownerID: UUID
    public let cursor: SocialFeedCursor?
    public let limit: Int

    public init(ownerID: UUID, cursor: SocialFeedCursor? = nil, limit: Int = 20) throws {
        guard (1...100).contains(limit) else { throw SocialContentError.invalidPageLimit }
        self.ownerID = ownerID
        self.cursor = cursor
        self.limit = limit
    }
}

public struct SocialNotificationPage: Codable, Equatable, Sendable {
    public let items: [SocialNotification]
    public let nextCursor: SocialFeedCursor?

    public init(items: [SocialNotification], nextCursor: SocialFeedCursor? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct SocialModerationWorkItem: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: SocialContentKind
    public let contentID: UUID
    public let ownerID: UUID
    public let body: String
    public let digest: String
    public let revision: Int64
    public let attempt: Int
    public let claimToken: UUID

    public init(
        id: UUID,
        kind: SocialContentKind,
        contentID: UUID,
        ownerID: UUID,
        body: String,
        digest: String,
        revision: Int64,
        attempt: Int,
        claimToken: UUID
    ) throws {
        guard revision > 0 else { throw SocialContentError.invalidModerationRevision }
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            throw SocialContentError.invalidModerationDigest
        }
        self.id = id
        self.kind = kind
        self.contentID = contentID
        self.ownerID = ownerID
        self.body = body
        self.digest = digest
        self.revision = revision
        self.attempt = max(1, attempt)
        self.claimToken = claimToken
    }
}

public enum SocialModerationResult: String, Codable, Sendable {
    case approved
    case rejected
}

public struct SocialModerationDecision: Codable, Equatable, Sendable {
    public let result: SocialModerationResult
    public let provider: String
    public let reason: String?

    public init(result: SocialModerationResult, provider: String = "application", reason: String? = nil) {
        self.result = result
        self.provider = String(provider.prefix(80))
        self.reason = reason.map { String($0.prefix(1000)) }
    }
}

public protocol SocialModerationProvider: Sendable {
    /// Providers receive only the content work item. Provider selection,
    /// consent, redaction, and cloud-data policy belong to the application.
    func moderate(_ workItem: SocialModerationWorkItem) async throws -> SocialModerationDecision
}

/// Persistence boundary for generic social content. A durable implementation
/// must commit a post/comment together with its moderation work, deduplicate
/// writes using the supplied key, serialize queue claims across replicas, and
/// publish feed/notification events only after guarded state transitions.
public protocol SocialContentStore: Sendable {
    func installSchema() async throws
    func publish(_ draft: SocialPostDraft) async throws -> SocialPost
    func comment(_ draft: SocialCommentDraft) async throws -> SocialComment
    func setReaction(_ reaction: SocialReaction) async throws -> Bool
    func removeReaction(_ reaction: SocialReaction) async throws -> Bool
    func feed(_ request: SocialFeedRequest) async throws -> SocialFeedPage
    func comments(_ request: SocialCommentRequest) async throws -> SocialCommentPage
    func notifications(_ request: SocialNotificationRequest) async throws -> SocialNotificationPage
    func claimModeration(workerID: UUID, leaseDuration: Duration, maximumAttempts: Int) async throws -> SocialModerationWorkItem?
    func completeModeration(_ item: SocialModerationWorkItem, decision: SocialModerationDecision) async throws -> Bool
    func retryModeration(_ item: SocialModerationWorkItem, errorCode: String, maximumAttempts: Int) async throws
}

/// Invokes moderation outside the storage transaction. If provider execution
/// fails, the store schedules a retry; if commit fails/has unknown outcome, the
/// lease is left for expiry and the provider is not immediately called again.
public struct SocialModerationWorker: Sendable {
    private let store: any SocialContentStore
    private let provider: any SocialModerationProvider
    private let workerID: UUID
    private let leaseDuration: Duration
    private let maximumAttempts: Int

    public init(
        store: any SocialContentStore,
        provider: any SocialModerationProvider,
        workerID: UUID = UUIDv7.generate(),
        leaseDuration: Duration = .seconds(60),
        maximumAttempts: Int = 5
    ) throws {
        guard leaseDuration > .zero, maximumAttempts > 0 else {
            throw SocialContentWorkerError.invalidConfiguration
        }
        self.store = store
        self.provider = provider
        self.workerID = workerID
        self.leaseDuration = leaseDuration
        self.maximumAttempts = maximumAttempts
    }

    @discardableResult
    public func runOnce() async throws -> Bool {
        guard let item = try await store.claimModeration(
            workerID: workerID,
            leaseDuration: leaseDuration,
            maximumAttempts: maximumAttempts
        ) else {
            return false
        }

        let decision: SocialModerationDecision
        do {
            decision = try await provider.moderate(item)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await store.retryModeration(
                item,
                errorCode: String(reflecting: type(of: error)),
                maximumAttempts: maximumAttempts
            )
            return true
        }

        _ = try await store.completeModeration(item, decision: decision)
        return true
    }
}

public enum SocialContentWorkerError: Error, Sendable, Equatable {
    case invalidConfiguration
}

private func validateIdempotencyKey(_ value: String) throws {
    guard (1...200).contains(value.utf8.count),
          value.utf8.allSatisfy({ $0 >= 33 && $0 != 127 }) else {
        throw SocialContentError.invalidIdempotencyKey
    }
}

import Foundation
import PearfyData

public enum SocialActorKind: String, Codable, Sendable {
    case person
    case page
    case community
}

public enum SocialVisibility: String, Codable, Sendable {
    case `public`
    case followers
    case `private`
}

public enum SocialFollowStatus: String, Codable, Sendable {
    case pending
    case accepted
}

public struct SocialActor: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// Reference to the application's existing identity; PearfySocial does not
    /// create or merge authentication users.
    public let ownerID: UUID
    public let kind: SocialActorKind
    public let handle: String
    public let visibility: SocialVisibility

    public init(
        id: UUID = UUIDv7.generate(),
        ownerID: UUID,
        kind: SocialActorKind,
        handle: String,
        visibility: SocialVisibility = .public
    ) throws {
        let normalized = handle.lowercased()
        guard !normalized.isEmpty,
              normalized.utf8.count <= 64,
              normalized.utf8.allSatisfy({
                  (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
              }),
              let first = normalized.utf8.first,
              (97...122).contains(first) || (48...57).contains(first),
              let last = normalized.utf8.last,
              (97...122).contains(last) || (48...57).contains(last) else {
            throw SocialGraphError.invalidHandle
        }
        self.id = id
        self.ownerID = ownerID
        self.kind = kind
        self.handle = normalized
        self.visibility = visibility
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                ownerID: container.decode(UUID.self, forKey: .ownerID),
                kind: container.decode(SocialActorKind.self, forKey: .kind),
                handle: container.decode(String.self, forKey: .handle),
                visibility: container.decode(SocialVisibility.self, forKey: .visibility)
            )
        } catch SocialGraphError.invalidHandle {
            throw DecodingError.dataCorruptedError(
                forKey: .handle,
                in: container,
                debugDescription: "Social actor handle does not satisfy the handle rules"
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case ownerID
        case kind
        case handle
        case visibility
    }
}

public enum SocialGraphError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidHandle
    case selfRelationship
    case actorNotFoundOrNotVisible
    case actorOwnershipRequired
    case blocked
    case invalidPersistedStatus(String)

    public var description: String {
        switch self {
        case .invalidHandle: "PEARFY_SOCIAL_001: invalid social handle"
        case .selfRelationship: "PEARFY_SOCIAL_002: actor cannot follow or block itself"
        case .actorNotFoundOrNotVisible: "PEARFY_SOCIAL_003: actor was not found or is not visible"
        case .actorOwnershipRequired: "PEARFY_SOCIAL_004: action requires ownership of the source actor"
        case .blocked: "PEARFY_SOCIAL_005: relationship is blocked"
        case .invalidPersistedStatus(let status): "PEARFY_SOCIAL_006: invalid persisted follow status '\(status)'"
        }
    }
}

public protocol SocialGraphStore: Sendable {
    func installSchema() async throws
    func createActor(_ actor: SocialActor) async throws
    func follow(ownerID: UUID, sourceActorID: UUID, targetActorID: UUID) async throws -> SocialFollowStatus
    func approveFollow(ownerID: UUID, sourceActorID: UUID, targetActorID: UUID) async throws
    func unfollow(ownerID: UUID, sourceActorID: UUID, targetActorID: UUID) async throws
    func block(ownerID: UUID, blockerActorID: UUID, blockedActorID: UUID) async throws
    func unblock(ownerID: UUID, blockerActorID: UUID, blockedActorID: UUID) async throws
    func canView(viewerOwnerID: UUID?, targetActorID: UUID) async throws -> Bool
}

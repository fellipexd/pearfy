import Crypto
import Foundation

/// Server-side configuration for short-lived, session-scoped game tickets.
public struct GameServerConfiguration: Sendable, Equatable {
    public let supportedProtocolVersion: UInt16
    public let ticketLifetime: TimeInterval
    public let maximumActiveTickets: Int

    public init(
        supportedProtocolVersion: UInt16 = 1,
        ticketLifetime: TimeInterval = 120,
        maximumActiveTickets: Int = 10_000
    ) throws {
        guard supportedProtocolVersion > 0 else { throw GameServerError.invalidConfiguration }
        guard ticketLifetime.isFinite, (1...3_600).contains(ticketLifetime) else {
            throw GameServerError.invalidConfiguration
        }
        guard maximumActiveTickets > 0 else { throw GameServerError.invalidConfiguration }
        self.supportedProtocolVersion = supportedProtocolVersion
        self.ticketLifetime = ticketLifetime
        self.maximumActiveTickets = maximumActiveTickets
    }
}

/// An opaque credential delivered to one player for one game session.
/// Its description is redacted; applications should never log `value`.
public struct GameSessionTicket: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: String

    public init(value: String) {
        self.value = value
    }

    public var bearerAuthorizationValue: String { "Bearer \(value)" }
    public var description: String { "<game-session-ticket:redacted>" }
    public var debugDescription: String { description }
}

/// Identity established by validating a session ticket.
public struct GameSessionPrincipal: Sendable, Equatable {
    public let sessionID: UUID
    public let playerID: UUID
    public let protocolVersion: UInt16

    public init(sessionID: UUID, playerID: UUID, protocolVersion: UInt16) {
        self.sessionID = sessionID
        self.playerID = playerID
        self.protocolVersion = protocolVersion
    }
}

/// Issues and verifies bounded, expiring HMAC-SHA256 tickets on the server.
/// The signing key must come from a server-side secret provider and contain at least 32 bytes.
public actor GameSessionTicketAuthority {
    private struct Claims: Codable, Sendable {
        let ticketID: UUID
        let sessionID: UUID
        let playerID: UUID
        let protocolVersion: UInt16
        let issuedAt: TimeInterval
        let expiresAt: TimeInterval
    }

    private let configuration: GameServerConfiguration
    private let signingKey: SymmetricKey
    private var activeTickets: [UUID: Date] = [:]

    public init(configuration: GameServerConfiguration, signingKey: Data) throws {
        guard signingKey.count >= 32 else { throw GameServerError.invalidSigningKey }
        self.configuration = configuration
        self.signingKey = SymmetricKey(data: signingKey)
    }

    public func issue(
        sessionID: UUID,
        playerID: UUID,
        now: Date = Date()
    ) throws -> GameSessionTicket {
        pruneExpiredTickets(now: now)
        guard activeTickets.count < configuration.maximumActiveTickets else {
            throw GameServerError.ticketCapacityReached
        }

        let expiresAt = now.addingTimeInterval(configuration.ticketLifetime)
        let claims = Claims(
            ticketID: UUID(),
            sessionID: sessionID,
            playerID: playerID,
            protocolVersion: configuration.supportedProtocolVersion,
            issuedAt: now.timeIntervalSince1970,
            expiresAt: expiresAt.timeIntervalSince1970
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = Self.base64URL(try encoder.encode(claims))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: signingKey)
        let token = "\(payload).\(Self.base64URL(Data(signature)))"
        activeTickets[claims.ticketID] = expiresAt
        return GameSessionTicket(value: token)
    }

    /// Returns the authenticated session identity only when the ticket is active,
    /// unexpired and bound to the expected session, player and protocol version.
    public func authenticate(
        _ ticket: GameSessionTicket,
        sessionID: UUID,
        playerID: UUID,
        protocolVersion: UInt16,
        now: Date = Date()
    ) -> GameSessionPrincipal? {
        pruneExpiredTickets(now: now)
        guard ticket.value.utf8.count <= 4_096 else { return nil }
        let parts = ticket.value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payloadData = Self.decodeBase64URL(String(parts[0])),
              let signatureData = Self.decodeBase64URL(String(parts[1])),
              HMAC<SHA256>.isValidAuthenticationCode(
                signatureData,
                authenticating: Data(parts[0].utf8),
                using: signingKey
              ),
              let claims = try? JSONDecoder().decode(Claims.self, from: payloadData),
              let activeExpiration = activeTickets[claims.ticketID],
              activeExpiration.timeIntervalSince1970 == claims.expiresAt,
              now.timeIntervalSince1970 >= claims.issuedAt,
              now.timeIntervalSince1970 < claims.expiresAt,
              claims.sessionID == sessionID,
              claims.playerID == playerID,
              claims.protocolVersion == protocolVersion,
              protocolVersion == configuration.supportedProtocolVersion else {
            return nil
        }
        return GameSessionPrincipal(
            sessionID: claims.sessionID,
            playerID: claims.playerID,
            protocolVersion: claims.protocolVersion
        )
    }

    /// Revokes a ticket immediately. An invalid or already revoked ticket returns `false`.
    @discardableResult
    public func revoke(_ ticket: GameSessionTicket, now: Date = Date()) -> Bool {
        guard let claims = verifiedClaims(ticket),
              let expiration = activeTickets[claims.ticketID],
              expiration > now else {
            pruneExpiredTickets(now: now)
            return false
        }
        activeTickets.removeValue(forKey: claims.ticketID)
        return true
    }

    public var activeTicketCount: Int { activeTickets.count }

    private func pruneExpiredTickets(now: Date) {
        activeTickets = activeTickets.filter { $0.value > now }
    }

    private func verifiedClaims(_ ticket: GameSessionTicket) -> Claims? {
        guard ticket.value.utf8.count <= 4_096 else { return nil }
        let parts = ticket.value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payloadData = Self.decodeBase64URL(String(parts[0])),
              let signatureData = Self.decodeBase64URL(String(parts[1])),
              HMAC<SHA256>.isValidAuthenticationCode(
                signatureData,
                authenticating: Data(parts[0].utf8),
                using: signingKey
              ) else { return nil }
        return try? JSONDecoder().decode(Claims.self, from: payloadData)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

/// Session details returned by an application's matchmaking or room service.
public struct GameSessionOffer: Sendable, Equatable {
    public let sessionID: UUID
    public let playerID: UUID
    public let gatewayURL: URL
    public let protocolVersion: UInt16
    public let ticket: GameSessionTicket

    public init(
        sessionID: UUID,
        playerID: UUID,
        gatewayURL: URL,
        protocolVersion: UInt16,
        ticket: GameSessionTicket
    ) throws {
        guard gatewayURL.scheme?.lowercased() == "wss", gatewayURL.host != nil,
              gatewayURL.user == nil, gatewayURL.password == nil,
              gatewayURL.query == nil, gatewayURL.fragment == nil,
              protocolVersion > 0 else { throw GameServerError.invalidSessionOffer }
        self.sessionID = sessionID
        self.playerID = playerID
        self.gatewayURL = gatewayURL
        self.protocolVersion = protocolVersion
        self.ticket = ticket
    }
}

/// Application-owned matchmaking and room lifecycle boundary.
/// Implementations should authorize the player before returning an offer and call
/// `GameSessionTicketAuthority.revoke` when a session ends.
public protocol GameMatchmaking: Sendable {
    func findGame(for playerID: UUID) async throws -> GameSessionOffer
    func createRoom(for playerID: UUID) async throws -> GameSessionOffer
    func leave(sessionID: UUID, playerID: UUID) async throws
}

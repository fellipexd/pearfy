import Crypto
import Foundation
import PearfyGameServer

public enum GameServerUDPAdmissionError: Error, Sendable, Equatable {
    case unauthorizedTicket
    case invalidConfiguration
}

/// Fresh, per-connection UDP material. Its description deliberately omits the key;
/// return the secret only over the authenticated confidential control plane.
public struct GameServerUDPAdmissionCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let channelID: UUID
    public let sessionSecret: SymmetricKey

    fileprivate init(channelID: UUID, sessionSecret: SymmetricKey) {
        self.channelID = channelID
        self.sessionSecret = sessionSecret
    }

    public var description: String { "<game-server-udp-credentials:redacted>" }
    public var debugDescription: String { description }
}

/// Authenticates a game ticket before creating a fresh encrypted datagram channel.
/// The channel ID is distinct from the shared game session ID, allowing each player
/// in one multiplayer session to have independent keys and replay windows.
public actor GameServerUDPAdmissionManager {
    private let ticketAuthority: GameSessionTicketAuthority
    private let server: GameServerUDPServer
    private let maximumPayloadBytes: Int

    public init(
        ticketAuthority: GameSessionTicketAuthority,
        server: GameServerUDPServer,
        maximumPayloadBytes: Int = 1_152
    ) throws {
        guard (1...1_152).contains(maximumPayloadBytes) else {
            throw GameServerUDPAdmissionError.invalidConfiguration
        }
        self.ticketAuthority = ticketAuthority
        self.server = server
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    /// Returns credentials only after the authority validates the ticket's
    /// session, player, expiry, revocation and protocol version. Every call creates
    /// a new channel ID and random 256-bit key, including reconnects.
    public func admit(
        ticket: GameSessionTicket,
        sessionID: UUID,
        playerID: UUID,
        protocolVersion: UInt16,
        now: Date = Date()
    ) async throws -> GameServerUDPAdmissionCredentials {
        guard let principal = await ticketAuthority.authenticate(
            ticket,
            sessionID: sessionID,
            playerID: playerID,
            protocolVersion: protocolVersion,
            now: now
        ) else {
            throw GameServerUDPAdmissionError.unauthorizedTicket
        }

        let channelID = UUID()
        let sessionSecret = SymmetricKey(size: .bits256)
        let codec = try GameServerSecureDatagramCodec(
            sessionID: channelID,
            sessionSecret: sessionSecret,
            role: .server,
            maximumPayloadBytes: maximumPayloadBytes
        )
        try await server.register(sessionID: channelID, principal: principal, codec: codec)
        return GameServerUDPAdmissionCredentials(channelID: channelID, sessionSecret: sessionSecret)
    }

    /// Remove the channel when its ticket is revoked, expires or its game session ends.
    public func revoke(channelID: UUID) async {
        await server.unregister(sessionID: channelID)
    }
}

import Crypto
import Foundation

/// Endpoint role for the Pearfy v1 authenticated datagram wire format.
public enum GameServerDatagramRole: Sendable, Equatable {
    case client
    case server
}

public enum GameServerSecureDatagramError: Error, Sendable, Equatable {
    case invalidConfiguration
    case payloadTooLarge
    case invalidPacket
    case wrongSession
    case authenticationFailed
    case replayDetected
    case sequenceExhausted
}

/// Thread-safe AEAD codec for bounded UDP gameplay packets.
///
/// A fresh 256-bit secret must be generated for each session and delivered through an
/// already authenticated confidential channel. Do not reuse it across reconnects. This
/// type deliberately does not perform ticket admission or key exchange.
public final class GameServerSecureDatagramCodec: @unchecked Sendable {
    public static let headerBytes = 32
    public static let authenticationTagBytes = 16
    public static let maximumUDPPayloadBytes = 65_507
    private static let maximumPlaintextBytes = maximumUDPPayloadBytes - headerBytes - authenticationTagBytes

    public let sessionID: UUID
    public let role: GameServerDatagramRole
    public let maximumPayloadBytes: Int
    public var acceptsClientPackets: Bool { role == .server }

    private let lock = NSLock()
    private let outboundKey: SymmetricKey
    private let inboundKey: SymmetricKey
    private let outboundDirection: UInt8
    private let inboundDirection: UInt8
    private var nextOutboundSequence: UInt64 = 1
    private var highestInboundSequence: UInt64 = 0
    private var inboundReplayWindow: UInt64 = 0

    public init(
        sessionID: UUID,
        sessionSecret: SymmetricKey,
        role: GameServerDatagramRole,
        maximumPayloadBytes: Int = 1_200
    ) throws {
        guard sessionSecret.bitCount == 256,
              (1...Self.maximumPlaintextBytes).contains(maximumPayloadBytes) else {
            throw GameServerSecureDatagramError.invalidConfiguration
        }
        self.sessionID = sessionID
        self.role = role
        self.maximumPayloadBytes = maximumPayloadBytes
        let sessionSalt = Self.uuidBytes(sessionID)
        let clientToServer = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sessionSecret,
            salt: sessionSalt,
            info: Data("pearfy-gameserver-udp-v1/client-to-server".utf8),
            outputByteCount: 32
        )
        let serverToClient = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sessionSecret,
            salt: sessionSalt,
            info: Data("pearfy-gameserver-udp-v1/server-to-client".utf8),
            outputByteCount: 32
        )
        switch role {
        case .client:
            outboundKey = clientToServer
            inboundKey = serverToClient
            outboundDirection = 0
            inboundDirection = 1
        case .server:
            outboundKey = serverToClient
            inboundKey = clientToServer
            outboundDirection = 1
            inboundDirection = 0
        }
    }

    /// Seals one packet. The monotonically increasing sequence is authenticated as AAD.
    public func seal(_ plaintext: Data) throws -> Data {
        guard plaintext.count <= maximumPayloadBytes else { throw GameServerSecureDatagramError.payloadTooLarge }
        lock.lock()
        defer { lock.unlock() }
        guard nextOutboundSequence < UInt64.max else { throw GameServerSecureDatagramError.sequenceExhausted }
        let sequence = nextOutboundSequence
        let header = Self.header(sessionID: sessionID, direction: outboundDirection, sequence: sequence)
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.seal(plaintext, using: outboundKey, nonce: try Self.nonce(sequence), authenticating: header)
        } catch {
            throw GameServerSecureDatagramError.authenticationFailed
        }
        nextOutboundSequence += 1
        var packet = header
        packet.append(box.ciphertext)
        packet.append(box.tag)
        return packet
    }

    /// Authenticates, decrypts and rejects duplicate or stale packets.
    public func open(_ packet: Data) throws -> Data {
        guard packet.count >= Self.headerBytes + Self.authenticationTagBytes,
              packet.count <= Self.headerBytes + maximumPayloadBytes + Self.authenticationTagBytes else {
            throw GameServerSecureDatagramError.invalidPacket
        }
        let header = Data(packet.prefix(Self.headerBytes))
        let bytes = Array(header)
        guard Array(bytes[0..<4]) == [0x50, 0x46, 0x53, 0x55], bytes[4] == 1,
              bytes[5] == inboundDirection, bytes[6] == 0, bytes[7] == 0 else {
            throw GameServerSecureDatagramError.invalidPacket
        }
        let receivedSessionID = Self.uuid(from: bytes[8..<24])
        guard receivedSessionID == sessionID else { throw GameServerSecureDatagramError.wrongSession }
        let sequence = bytes[24..<32].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard sequence > 0 else { throw GameServerSecureDatagramError.invalidPacket }

        lock.lock()
        defer { lock.unlock() }
        guard Self.isFresh(sequence, highest: highestInboundSequence, bitmap: inboundReplayWindow) else {
            throw GameServerSecureDatagramError.replayDetected
        }
        let cipherEnd = packet.count - Self.authenticationTagBytes
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.SealedBox(
                nonce: try Self.nonce(sequence),
                ciphertext: packet[Self.headerBytes..<cipherEnd],
                tag: packet[cipherEnd..<packet.count]
            )
        } catch {
            throw GameServerSecureDatagramError.invalidPacket
        }
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(box, using: inboundKey, authenticating: header)
        } catch {
            throw GameServerSecureDatagramError.authenticationFailed
        }
        Self.record(sequence, highest: &highestInboundSequence, bitmap: &inboundReplayWindow)
        return plaintext
    }

    /// Extracts only the routing identifier from a bounded v1 header. Authentication
    /// still occurs in `open(_:)` before the packet is delivered to the application.
    public static func sessionID(in packet: Data) -> UUID? {
        guard packet.count >= headerBytes + authenticationTagBytes else { return nil }
        let bytes = Array(packet.prefix(headerBytes))
        guard Array(bytes[0..<4]) == [0x50, 0x46, 0x53, 0x55], bytes[4] == 1 else { return nil }
        return uuid(from: bytes[8..<24])
    }

    private static func isFresh(_ sequence: UInt64, highest: UInt64, bitmap: UInt64) -> Bool {
        guard sequence > 0 else { return false }
        if sequence > highest { return true }
        let distance = highest - sequence
        guard distance < 64 else { return false }
        return bitmap & (UInt64(1) << distance) == 0
    }

    private static func record(_ sequence: UInt64, highest: inout UInt64, bitmap: inout UInt64) {
        if sequence > highest {
            let distance = sequence - highest
            bitmap = distance >= 64 ? 1 : (bitmap << distance) | 1
            highest = sequence
        } else {
            bitmap |= UInt64(1) << (highest - sequence)
        }
    }

    private static func nonce(_ sequence: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        var bigEndian = sequence.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    private static func header(sessionID: UUID, direction: UInt8, sequence: UInt64) -> Data {
        var result = Data([0x50, 0x46, 0x53, 0x55, 1, direction, 0, 0])
        result.append(uuidBytes(sessionID))
        var bigEndian = sequence.bigEndian
        withUnsafeBytes(of: &bigEndian) { result.append(contentsOf: $0) }
        return result
    }

    private static func uuidBytes(_ value: UUID) -> Data {
        withUnsafeBytes(of: value.uuid) { Data($0) }
    }

    private static func uuid(from bytes: ArraySlice<UInt8>) -> UUID {
        let value = Array(bytes)
        return UUID(uuid: (
            value[0], value[1], value[2], value[3], value[4], value[5], value[6], value[7],
            value[8], value[9], value[10], value[11], value[12], value[13], value[14], value[15]
        ))
    }
}

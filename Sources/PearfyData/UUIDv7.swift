import Foundation

/// Creates UUIDv7 identifiers with a Unix-millisecond timestamp and system
/// generated random bits. Entity macros can use this as the default UUID ID
/// strategy when model discovery is added.
public enum UUIDv7 {
    private static let maximumTimestamp = (UInt64(1) << 48) - 1

    public static func generate() -> UUID {
        let milliseconds = max(0, Date().timeIntervalSince1970 * 1_000)
        let timestamp = min(UInt64(milliseconds), maximumTimestamp)
        var generator = SystemRandomNumberGenerator()
        let randomBytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return make(timestampMilliseconds: timestamp, randomBytes: randomBytes)
    }

    /// Extracts the 48-bit Unix-millisecond timestamp from a UUIDv7 value.
    /// Returns `nil` for UUIDs using another version.
    public static func timestampMilliseconds(from uuid: UUID) -> UInt64? {
        let bytes = uuid.uuid
        let octets: [UInt8] = [
            bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5,
            bytes.6, bytes.7, bytes.8, bytes.9, bytes.10, bytes.11,
            bytes.12, bytes.13, bytes.14, bytes.15
        ]
        guard octets[6] >> 4 == 7 else { return nil }
        return octets[0..<6].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func make(timestampMilliseconds: UInt64, randomBytes: [UInt8]) -> UUID {
        var bytes = randomBytes
        bytes[0] = UInt8((timestampMilliseconds >> 40) & 0xff)
        bytes[1] = UInt8((timestampMilliseconds >> 32) & 0xff)
        bytes[2] = UInt8((timestampMilliseconds >> 24) & 0xff)
        bytes[3] = UInt8((timestampMilliseconds >> 16) & 0xff)
        bytes[4] = UInt8((timestampMilliseconds >> 8) & 0xff)
        bytes[5] = UInt8(timestampMilliseconds & 0xff)
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

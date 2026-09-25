import Foundation

public struct MessageEnvelope: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let topic: String
    public let payload: Data
    public let idempotencyKey: String?
    public let deliveryAttempt: Int

    public init(id: UUID = UUID(), topic: String, payload: Data, idempotencyKey: String? = nil, deliveryAttempt: Int = 0) {
        self.id = id
        self.topic = topic
        self.payload = payload
        self.idempotencyKey = idempotencyKey
        self.deliveryAttempt = max(0, deliveryAttempt)
    }

    public func withDeliveryAttempt(_ attempt: Int) -> MessageEnvelope {
        MessageEnvelope(id: id, topic: topic, payload: payload, idempotencyKey: idempotencyKey, deliveryAttempt: attempt)
    }
}

public enum MessagingError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidTopic
    case topicTooLong(Int)
    case invalidIdempotencyKey
    case idempotencyKeyTooLong(Int)
    case capacityExceeded
    case payloadTooLarge(Int)
    case unknownDelivery(UUID)

    public var description: String {
        switch self {
        case .invalidTopic: "PEARFY_MSG_001: topic must not be empty"
        case .topicTooLong(let maximumBytes): "PEARFY_MSG_002: topic exceeds \(maximumBytes) bytes"
        case .invalidIdempotencyKey: "PEARFY_MSG_003: idempotency key must not be empty"
        case .idempotencyKeyTooLong(let maximumBytes): "PEARFY_MSG_004: idempotency key exceeds \(maximumBytes) bytes"
        case .capacityExceeded: "PEARFY_MSG_005: in-memory broker capacity exceeded"
        case .payloadTooLarge(let maximumBytes): "PEARFY_MSG_006: message payload exceeds \(maximumBytes) bytes"
        case .unknownDelivery(let id): "PEARFY_MSG_007: unknown message delivery \(id)"
        }
    }
}

public protocol MessageBroker: Sendable {
    @discardableResult
    func publish(topic: String, payload: Data, idempotencyKey: String?) async throws -> Bool
    func receive(topic: String) async throws -> MessageEnvelope?
    func acknowledge(_ id: UUID) async throws
    func reject(_ id: UUID) async throws
}

/// Deterministic test/development broker with bounded capacity, acknowledgements,
/// idempotency keys, retries, and a dead-letter queue.
public actor InMemoryMessageBroker: MessageBroker {
    private let capacity: Int
    private let maximumAttempts: Int
    private let maximumPayloadBytes: Int
    private let maximumTopicBytes: Int
    private let maximumIdempotencyKeyBytes: Int
    private let maximumQueuedBytes: Int
    private let maximumDeadLetterMessages: Int
    private let maximumDeadLetterBytes: Int
    private let maximumIdempotencyKeys: Int
    private var pending: [MessageEnvelope] = []
    private var inFlight: [UUID: MessageEnvelope] = [:]
    private var deadLetters: [MessageEnvelope] = []
    private var idempotencyKeys: Set<String> = []
    private var idempotencyOrder: [String] = []
    private var queuedBytes = 0
    private var deadLetterBytes = 0

    public init(
        capacity: Int = 1_000,
        maximumAttempts: Int = 3,
        maximumPayloadBytes: Int = 1_048_576,
        maximumTopicBytes: Int = 256,
        maximumIdempotencyKeyBytes: Int = 256,
        maximumQueuedBytes: Int = 64 * 1_024 * 1_024,
        maximumDeadLetterMessages: Int = 1_000,
        maximumDeadLetterBytes: Int = 16 * 1_024 * 1_024,
        maximumIdempotencyKeys: Int = 10_000
    ) {
        self.capacity = max(1, capacity)
        self.maximumAttempts = max(1, maximumAttempts)
        self.maximumPayloadBytes = max(1, maximumPayloadBytes)
        self.maximumTopicBytes = max(1, maximumTopicBytes)
        self.maximumIdempotencyKeyBytes = max(1, maximumIdempotencyKeyBytes)
        self.maximumQueuedBytes = max(1, maximumQueuedBytes)
        self.maximumDeadLetterMessages = max(1, maximumDeadLetterMessages)
        self.maximumDeadLetterBytes = max(self.maximumPayloadBytes, maximumDeadLetterBytes)
        self.maximumIdempotencyKeys = max(1, maximumIdempotencyKeys)
    }

    @discardableResult
    public func publish(topic: String, payload: Data, idempotencyKey: String? = nil) throws -> Bool {
        guard !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              topic == topic.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw MessagingError.invalidTopic
        }
        guard topic.utf8.count <= maximumTopicBytes else { throw MessagingError.topicTooLong(maximumTopicBytes) }
        if let idempotencyKey {
            guard !idempotencyKey.isEmpty else { throw MessagingError.invalidIdempotencyKey }
            guard idempotencyKey.utf8.count <= maximumIdempotencyKeyBytes else {
                throw MessagingError.idempotencyKeyTooLong(maximumIdempotencyKeyBytes)
            }
            if idempotencyKeys.contains(idempotencyKey) { return false }
        }
        guard payload.count <= maximumPayloadBytes else {
            throw MessagingError.payloadTooLarge(maximumPayloadBytes)
        }
        guard pending.count + inFlight.count < capacity,
              payload.count <= maximumQueuedBytes - queuedBytes else { throw MessagingError.capacityExceeded }
        if let idempotencyKey { rememberIdempotencyKey(idempotencyKey) }
        pending.append(MessageEnvelope(id: UUID(), topic: topic, payload: payload, idempotencyKey: idempotencyKey))
        queuedBytes += payload.count
        return true
    }

    public func receive(topic: String) throws -> MessageEnvelope? {
        guard let index = pending.firstIndex(where: { $0.topic == topic }) else { return nil }
        let message = pending.remove(at: index)
        inFlight[message.id] = message
        return message
    }

    public func acknowledge(_ id: UUID) throws {
        guard let message = inFlight.removeValue(forKey: id) else { throw MessagingError.unknownDelivery(id) }
        queuedBytes -= message.payload.count
    }

    public func reject(_ id: UUID) throws {
        guard let message = inFlight.removeValue(forKey: id) else { throw MessagingError.unknownDelivery(id) }
        let retry = message.withDeliveryAttempt(message.deliveryAttempt + 1)
        if retry.deliveryAttempt >= maximumAttempts {
            queuedBytes -= message.payload.count
            appendDeadLetter(retry)
        } else {
            pending.append(retry)
        }
    }

    public func deadLetterMessages() -> [MessageEnvelope] { deadLetters }
    public func pendingCount() -> Int { pending.count }
    public func inFlightCount() -> Int { inFlight.count }
    public func queuedByteCount() -> Int { queuedBytes }
    public func deadLetterByteCount() -> Int { deadLetterBytes }

    private func rememberIdempotencyKey(_ key: String) {
        idempotencyKeys.insert(key)
        idempotencyOrder.append(key)
        while idempotencyOrder.count > maximumIdempotencyKeys {
            idempotencyKeys.remove(idempotencyOrder.removeFirst())
        }
    }

    private func appendDeadLetter(_ message: MessageEnvelope) {
        deadLetters.append(message)
        deadLetterBytes += message.payload.count
        while deadLetters.count > maximumDeadLetterMessages || deadLetterBytes > maximumDeadLetterBytes {
            let oldest = deadLetters.removeFirst()
            deadLetterBytes -= oldest.payload.count
        }
    }
}

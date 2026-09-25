import Foundation
import PearfyMessaging
import Testing

@Test func brokerBoundsCapacityAndDeduplicatesIdempotencyKeys() async throws {
    let broker = InMemoryMessageBroker(capacity: 1)
    #expect(try await broker.publish(topic: "payment", payload: Data("one".utf8), idempotencyKey: "event-1"))
    #expect(!(try await broker.publish(topic: "payment", payload: Data("duplicate".utf8), idempotencyKey: "event-1")))

    var capacityError: MessagingError?
    do {
        _ = try await broker.publish(topic: "payment", payload: Data("two".utf8))
    } catch let error as MessagingError {
        capacityError = error
    }
    #expect(capacityError == .capacityExceeded)
}

@Test func brokerRetriesRejectedMessagesThenMovesThemToDeadLetters() async throws {
    let broker = InMemoryMessageBroker(capacity: 4, maximumAttempts: 2)
    try await broker.publish(topic: "orders", payload: Data("order".utf8))

    let first = try #require(try await broker.receive(topic: "orders"))
    try await broker.reject(first.id)
    let retry = try #require(try await broker.receive(topic: "orders"))
    #expect(retry.deliveryAttempt == 1)
    try await broker.reject(retry.id)

    let deadLetters = await broker.deadLetterMessages()
    #expect(deadLetters.count == 1)
    #expect(deadLetters[0].deliveryAttempt == 2)
    #expect(await broker.pendingCount() == 0)
    #expect(await broker.inFlightCount() == 0)
}

@Test func brokerBoundsPayloadQueuedBytesDeadLettersAndDeduplicationWindow() async throws {
    let broker = InMemoryMessageBroker(
        capacity: 4,
        maximumAttempts: 1,
        maximumPayloadBytes: 4,
        maximumTopicBytes: 8,
        maximumIdempotencyKeyBytes: 8,
        maximumQueuedBytes: 4,
        maximumDeadLetterMessages: 1,
        maximumDeadLetterBytes: 4,
        maximumIdempotencyKeys: 1
    )
    let payload = Data("four".utf8)
    try await broker.publish(topic: "events", payload: payload, idempotencyKey: "event-1")
    let first = try #require(try await broker.receive(topic: "events"))
    #expect(await broker.queuedByteCount() == 4)

    var queueBytesRejected = false
    do {
        try await broker.publish(topic: "events", payload: Data([1]))
    } catch MessagingError.capacityExceeded {
        queueBytesRejected = true
    }
    #expect(queueBytesRejected)
    try await broker.reject(first.id)
    #expect(await broker.queuedByteCount() == 0)
    #expect(await broker.deadLetterByteCount() == 4)

    var payloadRejected = false
    do {
        try await broker.publish(topic: "events", payload: Data(repeating: 1, count: 5))
    } catch MessagingError.payloadTooLarge(4) {
        payloadRejected = true
    }
    #expect(payloadRejected)

    var topicRejected = false
    do {
        try await broker.publish(topic: "topic-name-too-long", payload: Data([1]))
    } catch MessagingError.topicTooLong(8) {
        topicRejected = true
    }
    #expect(topicRejected)

    var idempotencyKeyRejected = false
    do {
        try await broker.publish(topic: "events", payload: Data([1]), idempotencyKey: "key-too-long")
    } catch MessagingError.idempotencyKeyTooLong(8) {
        idempotencyKeyRejected = true
    }
    #expect(idempotencyKeyRejected)

    try await broker.publish(topic: "events", payload: Data([1]), idempotencyKey: "event-2")
    let second = try #require(try await broker.receive(topic: "events"))
    try await broker.reject(second.id)
    let deadLetters = await broker.deadLetterMessages()
    #expect(deadLetters.count == 1)
    #expect(deadLetters[0].id == second.id)
    #expect(await broker.deadLetterByteCount() == 1)

    // The one-key dedup window has now evicted event-1, so it may be accepted again.
    #expect(try await broker.publish(topic: "events", payload: Data([1]), idempotencyKey: "event-1"))
}

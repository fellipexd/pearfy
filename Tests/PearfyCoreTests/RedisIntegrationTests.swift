import Foundation
import PearfyCache
import PearfyRedis
import Testing

@Test func redisCacheIntegrationCoversRoundTripNamespaceTTLAndRemoval() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_REDIS_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_REDIS_PORT"] ?? "6379") ?? 6379
    let prefix = "pearfy_test_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    let configuration = try RedisCacheConfiguration(
        host: host,
        port: port,
        username: ProcessInfo.processInfo.environment["PEARFY_TEST_REDIS_USERNAME"],
        password: ProcessInfo.processInfo.environment["PEARFY_TEST_REDIS_PASSWORD"],
        keyPrefix: prefix,
        maximumConnections: 1
    )
    let cache = RedisCacheStore(configuration: configuration)
    try await cache.start()

    do {
        let firstTenant = try CacheKey(namespace: "accounts", tenant: "one", value: "42")
        let secondTenant = try CacheKey(namespace: "accounts", tenant: "two", value: "42")
        try await cache.set(RedisCacheValue(name: "Pearfy"), for: firstTenant)
        #expect(try await cache.value(for: firstTenant, as: RedisCacheValue.self) == RedisCacheValue(name: "Pearfy"))
        #expect(try await cache.value(for: secondTenant, as: RedisCacheValue.self) == nil)

        let expiring = try CacheKey(namespace: "sessions", tenant: "one", value: "short")
        try await cache.set(RedisCacheValue(name: "temporary"), for: expiring, ttl: .milliseconds(60))
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await cache.value(for: expiring, as: RedisCacheValue.self) == nil)

        let parallelValues = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let key = try CacheKey(namespace: "parallel", tenant: "one", value: "\(index)")
                    try await cache.set(RedisCacheValue(name: "\(index)"), for: key)
                    guard let value = try await cache.value(for: key, as: RedisCacheValue.self),
                          let decoded = Int(value.name) else { return -1 }
                    return decoded
                }
            }
            var values: [Int] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(Set(parallelValues) == Set(0..<12))
        try await cache.removeAll(namespace: "parallel", tenant: "one")

        try await cache.removeAll(namespace: "accounts", tenant: "one")
        #expect(try await cache.value(for: firstTenant, as: RedisCacheValue.self) == nil)
        #expect(try await cache.value(for: secondTenant, as: RedisCacheValue.self) == nil)
    } catch {
        try? await cache.stop()
        throw error
    }
    try await cache.stop()
}

private struct RedisCacheValue: Codable, Sendable, Equatable {
    let name: String
}

@Test func redisMessageBrokerIntegrationBoundsQueueAndSupportsAckRetryAndDeadLetters() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_REDIS_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_REDIS_PORT"] ?? "6379") ?? 6379
    let prefix = "pearfy_broker_test_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    let configuration = try RedisMessageBrokerConfiguration(
        host: host,
        port: port,
        keyPrefix: prefix,
        consumerID: "integration",
        maximumConnections: 1,
        maximumTopicCount: 1,
        maximumMessagesPerTopic: 2,
        maximumPayloadBytes: 32,
        maximumQueuedBytesPerTopic: 64,
        maximumDeliveryAttempts: 2,
        retryBackoffMilliseconds: 0,
        maximumRetryBackoffMilliseconds: 0,
        maximumDeadLetterMessages: 1,
        maximumDeadLetterBytes: 32
    )
    let broker = RedisMessageBroker(configuration: configuration)
    try await broker.start()

    do {
        #expect(try await broker.publish(topic: "orders", payload: Data("first".utf8), idempotencyKey: "event-1"))
        #expect(!(try await broker.publish(topic: "orders", payload: Data("duplicate".utf8), idempotencyKey: "event-1")))
        let first = try #require(try await broker.receive(topic: "orders"))
        #expect(first.deliveryAttempt == 0)
        try await broker.publish(topic: "orders", payload: Data("second".utf8), idempotencyKey: "event-2")

        var capacityRejected = false
        do {
            try await broker.publish(topic: "orders", payload: Data("third".utf8))
        } catch RedisMessageBrokerError.capacityExceeded {
            capacityRejected = true
        }
        #expect(capacityRejected)

        let second = try #require(try await broker.receive(topic: "orders"))
        #expect(String(decoding: second.payload, as: UTF8.self) == "second")
        try await broker.acknowledge(second.id)

        try await broker.reject(first.id)
        let retry = try #require(try await broker.receive(topic: "orders"))
        #expect(retry.id == first.id)
        #expect(retry.deliveryAttempt == 1)
        try await broker.reject(retry.id)

        let deadLetters = try await broker.deadLetterMessages(topic: "orders")
        #expect(deadLetters.count == 1)
        #expect(deadLetters[0].id == first.id)
        #expect(deadLetters[0].deliveryAttempt == 2)
        #expect(try await broker.queuedByteCount(topic: "orders") == 0)

        var topicLimitRejected = false
        do {
            try await broker.publish(topic: "second-topic", payload: Data([1]))
        } catch RedisMessageBrokerError.topicLimitExceeded(1) {
            topicLimitRejected = true
        }
        #expect(topicLimitRejected)
    } catch {
        try? await broker.stop()
        throw error
    }
    try await broker.stop()
}

@Test func redisMessageBrokerRecoversUnacknowledgedMessagesAfterRestart() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_REDIS_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_REDIS_PORT"] ?? "6379") ?? 6379
    let configuration = try RedisMessageBrokerConfiguration(
        host: host,
        port: port,
        keyPrefix: "pearfy_restart_test_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
        consumerID: "stable-worker",
        maximumConnections: 1,
        retryBackoffMilliseconds: 0,
        maximumRetryBackoffMilliseconds: 0
    )
    let firstRun = RedisMessageBroker(configuration: configuration)
    try await firstRun.start()
    try await firstRun.publish(topic: "recovery", payload: Data("pending".utf8))
    let delivered = try #require(try await firstRun.receive(topic: "recovery"))
    try await firstRun.stop()

    let restarted = RedisMessageBroker(configuration: configuration)
    try await restarted.start()
    do {
        let recovered = try #require(try await restarted.receive(topic: "recovery"))
        #expect(recovered.id == delivered.id)
        #expect(recovered.payload == delivered.payload)
        try await restarted.acknowledge(recovered.id)
    } catch {
        try? await restarted.stop()
        throw error
    }
    try await restarted.stop()
}

@Test func redisMessageBrokerSharesBoundedTopicQueueAcrossDistinctConsumers() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_REDIS_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_REDIS_PORT"] ?? "6379") ?? 6379
    let prefix = "pearfy_workers_test_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    let firstConfiguration = try RedisMessageBrokerConfiguration(
        host: host,
        port: port,
        keyPrefix: prefix,
        consumerID: "worker-a",
        maximumConnections: 1
    )
    let secondConfiguration = try RedisMessageBrokerConfiguration(
        host: host,
        port: port,
        keyPrefix: prefix,
        consumerID: "worker-b",
        maximumConnections: 1
    )
    let firstWorker = RedisMessageBroker(configuration: firstConfiguration)
    let secondWorker = RedisMessageBroker(configuration: secondConfiguration)
    try await firstWorker.start()
    try await secondWorker.start()

    do {
        try await firstWorker.publish(topic: "jobs", payload: Data("single-delivery".utf8))
        let delivery = try #require(try await firstWorker.receive(topic: "jobs"))
        #expect(try await secondWorker.receive(topic: "jobs") == nil)
        try await firstWorker.acknowledge(delivery.id)
        #expect(try await firstWorker.queuedByteCount(topic: "jobs") == 0)
    } catch {
        try? await firstWorker.stop()
        try? await secondWorker.stop()
        throw error
    }
    try await firstWorker.stop()
    try await secondWorker.stop()
}

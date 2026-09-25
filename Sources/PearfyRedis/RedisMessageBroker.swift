import Foundation
import NIOCore
import NIOPosix
import PearfyContext
import PearfyMessaging
@preconcurrency import RediStack

public struct RedisMessageBrokerConfiguration: Sendable {
    public let host: String
    public let port: Int
    public let username: String?
    public let password: String?
    public let database: Int
    public let keyPrefix: String
    public let consumerID: String
    public let maximumConnections: Int
    public let maximumTopicCount: Int
    public let connectionRetryTimeoutMilliseconds: Int64
    public let maximumMessagesPerTopic: Int
    public let maximumPayloadBytes: Int
    public let maximumQueuedBytesPerTopic: Int
    public let maximumDeliveryAttempts: Int
    public let retryBackoffMilliseconds: Int64
    public let maximumRetryBackoffMilliseconds: Int64
    public let deduplicationTTLMilliseconds: Int64
    public let maximumDeadLetterMessages: Int
    public let maximumDeadLetterBytes: Int

    public init(
        host: String = "127.0.0.1",
        port: Int = 6379,
        username: String? = nil,
        password: String? = nil,
        database: Int = 0,
        keyPrefix: String = "pearfy",
        consumerID: String = "default",
        maximumConnections: Int = 8,
        maximumTopicCount: Int = 256,
        connectionRetryTimeoutMilliseconds: Int64 = 5_000,
        maximumMessagesPerTopic: Int = 10_000,
        maximumPayloadBytes: Int = 1_048_576,
        maximumQueuedBytesPerTopic: Int = 64 * 1_024 * 1_024,
        maximumDeliveryAttempts: Int = 5,
        retryBackoffMilliseconds: Int64 = 25,
        maximumRetryBackoffMilliseconds: Int64 = 5_000,
        deduplicationTTLMilliseconds: Int64 = 86_400_000,
        maximumDeadLetterMessages: Int = 1_000,
        maximumDeadLetterBytes: Int = 16 * 1_024 * 1_024
    ) throws {
        let validPrefix = !keyPrefix.isEmpty && keyPrefix.utf8.count <= 64 && keyPrefix.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
        guard !host.isEmpty, (1...65_535).contains(port), database >= 0, validPrefix,
              !consumerID.isEmpty, consumerID.utf8.count <= 128,
              consumerID.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
              }),
              (1...512).contains(maximumConnections), connectionRetryTimeoutMilliseconds > 0,
              maximumTopicCount > 0,
              maximumMessagesPerTopic > 0, maximumPayloadBytes > 0,
              maximumQueuedBytesPerTopic >= maximumPayloadBytes, maximumDeliveryAttempts > 0,
              retryBackoffMilliseconds >= 0, maximumRetryBackoffMilliseconds >= retryBackoffMilliseconds,
              deduplicationTTLMilliseconds > 0, maximumDeadLetterMessages > 0,
              maximumDeadLetterBytes >= maximumPayloadBytes,
              username?.isEmpty != true, password?.isEmpty != true,
              username == nil || password != nil
        else {
            throw RedisMessageBrokerError.invalidConfiguration
        }
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.keyPrefix = keyPrefix
        self.consumerID = consumerID
        self.maximumConnections = maximumConnections
        self.maximumTopicCount = maximumTopicCount
        self.connectionRetryTimeoutMilliseconds = connectionRetryTimeoutMilliseconds
        self.maximumMessagesPerTopic = maximumMessagesPerTopic
        self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumQueuedBytesPerTopic = maximumQueuedBytesPerTopic
        self.maximumDeliveryAttempts = maximumDeliveryAttempts
        self.retryBackoffMilliseconds = retryBackoffMilliseconds
        self.maximumRetryBackoffMilliseconds = maximumRetryBackoffMilliseconds
        self.deduplicationTTLMilliseconds = deduplicationTTLMilliseconds
        self.maximumDeadLetterMessages = maximumDeadLetterMessages
        self.maximumDeadLetterBytes = maximumDeadLetterBytes
    }
}

public enum RedisMessageBrokerError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidConfiguration
    case invalidTopic
    case invalidIdempotencyKey
    case topicTooLong(Int)
    case idempotencyKeyTooLong(Int)
    case topicLimitExceeded(Int)
    case payloadTooLarge(Int)
    case capacityExceeded
    case notStarted
    case unknownDelivery(UUID)
    case invalidResponse
    case shutdown(String)

    public var description: String {
        switch self {
        case .invalidConfiguration: "PEARFY_REDIS_MSG_001: invalid Redis broker configuration"
        case .invalidTopic: "PEARFY_REDIS_MSG_002: topic must be a bounded non-empty identifier"
        case .invalidIdempotencyKey: "PEARFY_REDIS_MSG_003: idempotency key must not be empty"
        case .topicTooLong(let bytes): "PEARFY_REDIS_MSG_004: topic exceeds \(bytes) bytes"
        case .idempotencyKeyTooLong(let bytes): "PEARFY_REDIS_MSG_005: idempotency key exceeds \(bytes) bytes"
        case .topicLimitExceeded(let maximum): "PEARFY_REDIS_MSG_006: maximum Redis broker topics is \(maximum)"
        case .payloadTooLarge(let bytes): "PEARFY_REDIS_MSG_007: message payload exceeds \(bytes) bytes"
        case .capacityExceeded: "PEARFY_REDIS_MSG_008: Redis broker topic capacity exceeded"
        case .notStarted: "PEARFY_REDIS_MSG_009: Redis broker has not started"
        case .unknownDelivery(let id): "PEARFY_REDIS_MSG_010: unknown Redis message delivery \(id)"
        case .invalidResponse: "PEARFY_REDIS_MSG_011: unexpected Redis command response"
        case .shutdown(let message): "PEARFY_REDIS_MSG_012: Redis broker shutdown failed: \(message)"
        }
    }
}

private struct RedisMessageRecord: Codable {
    let id: String
    let topic: String
    let payload: Data
    let payloadBytes: Int
    let idempotencyKey: String?
    var deliveryAttempt: Int

    init(_ envelope: MessageEnvelope) {
        id = envelope.id.uuidString
        topic = envelope.topic
        payload = envelope.payload
        payloadBytes = envelope.payload.count
        idempotencyKey = envelope.idempotencyKey
        deliveryAttempt = envelope.deliveryAttempt
    }

    var envelope: MessageEnvelope? {
        guard let uuid = UUID(uuidString: id), payload.count == payloadBytes else { return nil }
        return MessageEnvelope(
            id: uuid,
            topic: topic,
            payload: payload,
            idempotencyKey: idempotencyKey,
            deliveryAttempt: deliveryAttempt
        )
    }
}

/// Redis list-backed broker with atomic bounded publish, ack/reject, retries and
/// a bounded dead-letter list. Each concurrent worker must have a stable unique
/// `consumerID`; startup recovers messages left in that worker's processing list.
public actor RedisMessageBroker: MessageBroker, ApplicationLifecycle {
    private static let recoverProcessingScript = """
    local moved = 0
    while true do
      local value = redis.call('RPOPLPUSH', KEYS[1], KEYS[2])
      if not value then break end
      local record = cjson.decode(value)
      redis.call('HDEL', KEYS[3], record.id)
      moved = moved + 1
    end
    if moved > 0 then
      local processingCount = tonumber(redis.call('GET', KEYS[4]) or '0') - moved
      if processingCount <= 0 then redis.call('DEL', KEYS[4]) else redis.call('SET', KEYS[4], tostring(processingCount)) end
    end
    return moved
    """

    private static let receiveScript = """
    local value = redis.call('RPOPLPUSH', KEYS[1], KEYS[2])
    if not value then return false end
    local record = cjson.decode(value)
    redis.call('HSET', KEYS[4], record.id, record.topic)
    redis.call('INCR', KEYS[3])
    return value
    """

    private static let deliveryAttemptScript = """
    local messages = redis.call('LRANGE', KEYS[1], 0, -1)
    for _, raw in ipairs(messages) do
      local record = cjson.decode(raw)
      if record.id == ARGV[1] then return tonumber(record.deliveryAttempt) end
    end
    return -1
    """

    private static let publishScript = """
    local dedupe = ARGV[5]
    if dedupe ~= '' then
      local accepted = redis.call('SET', dedupe, '1', 'NX', 'PX', ARGV[6])
      if not accepted then return 0 end
    end
    if redis.call('SISMEMBER', KEYS[4], ARGV[7]) == 0 and redis.call('SCARD', KEYS[4]) >= tonumber(ARGV[8]) then
      if dedupe ~= '' then redis.call('DEL', dedupe) end
      return -2
    end
    local depth = redis.call('LLEN', KEYS[1]) + tonumber(redis.call('GET', KEYS[2]) or '0')
    local queuedBytes = tonumber(redis.call('GET', KEYS[3]) or '0')
    local payloadBytes = tonumber(ARGV[2])
    if depth >= tonumber(ARGV[1]) or queuedBytes + payloadBytes > tonumber(ARGV[3]) then
      if dedupe ~= '' then redis.call('DEL', dedupe) end
      return -1
    end
    redis.call('LPUSH', KEYS[1], ARGV[4])
    redis.call('SET', KEYS[3], tostring(queuedBytes + payloadBytes))
    redis.call('SADD', KEYS[4], ARGV[7])
    return 1
    """

    private static let acknowledgeScript = """
    local messages = redis.call('LRANGE', KEYS[1], 0, -1)
    for _, raw in ipairs(messages) do
      local record = cjson.decode(raw)
      if record.id == ARGV[1] then
        redis.call('LREM', KEYS[1], 1, raw)
        redis.call('HDEL', KEYS[4], ARGV[1])
        local processingCount = tonumber(redis.call('GET', KEYS[2]) or '0') - 1
        if processingCount <= 0 then redis.call('DEL', KEYS[2]) else redis.call('SET', KEYS[2], tostring(processingCount)) end
        local remaining = tonumber(redis.call('GET', KEYS[3]) or '0') - tonumber(record.payloadBytes)
        if remaining <= 0 then redis.call('DEL', KEYS[3]) else redis.call('SET', KEYS[3], tostring(remaining)) end
        return 1
      end
    end
    return 0
    """

    private static let rejectScript = """
    local messages = redis.call('LRANGE', KEYS[2], 0, -1)
    for _, raw in ipairs(messages) do
      local record = cjson.decode(raw)
      if record.id == ARGV[1] then
        record.deliveryAttempt = record.deliveryAttempt + 1
        local updated = cjson.encode(record)
        redis.call('LREM', KEYS[2], 1, raw)
        redis.call('HDEL', KEYS[7], ARGV[1])
        local processingCount = tonumber(redis.call('GET', KEYS[3]) or '0') - 1
        if processingCount <= 0 then redis.call('DEL', KEYS[3]) else redis.call('SET', KEYS[3], tostring(processingCount)) end
        if record.deliveryAttempt >= tonumber(ARGV[2]) then
          local queuedBytes = tonumber(redis.call('GET', KEYS[4]) or '0') - tonumber(record.payloadBytes)
          if queuedBytes <= 0 then redis.call('DEL', KEYS[4]) else redis.call('SET', KEYS[4], tostring(queuedBytes)) end
          redis.call('RPUSH', KEYS[5], updated)
          local deadBytes = tonumber(redis.call('GET', KEYS[6]) or '0') + tonumber(record.payloadBytes)
          redis.call('SET', KEYS[6], tostring(deadBytes))
          while redis.call('LLEN', KEYS[5]) > tonumber(ARGV[3]) or deadBytes > tonumber(ARGV[4]) do
            local oldest = redis.call('LPOP', KEYS[5])
            if not oldest then break end
            deadBytes = deadBytes - tonumber(cjson.decode(oldest).payloadBytes)
            if deadBytes <= 0 then redis.call('DEL', KEYS[6]) else redis.call('SET', KEYS[6], tostring(deadBytes)) end
          end
          return -1
        end
        redis.call('LPUSH', KEYS[1], updated)
        return record.deliveryAttempt
      end
    end
    return 0
    """

    public nonisolated let name = "Pearfy Redis message broker"

    private let configuration: RedisMessageBrokerConfiguration
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var pool: RedisConnectionPool?
    private var starting = false

    public init(configuration: RedisMessageBrokerConfiguration) {
        self.configuration = configuration
    }

    public func start() async throws {
        guard pool == nil else { return }
        guard !starting else { throw RedisMessageBrokerError.invalidConfiguration }
        starting = true
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var candidatePool: RedisConnectionPool?
        do {
            let address = try SocketAddress.makeAddressResolvingHost(configuration.host, port: configuration.port)
            let factory = RedisConnectionPool.ConnectionFactoryConfiguration(
                connectionInitialDatabase: configuration.database,
                connectionUsername: configuration.username,
                connectionPassword: configuration.password
            )
            let poolConfiguration = RedisConnectionPool.Configuration(
                initialServerConnectionAddresses: [address],
                maximumConnectionCount: .maximumActiveConnections(configuration.maximumConnections),
                connectionFactoryConfiguration: factory,
                minimumConnectionCount: 1,
                connectionRetryTimeout: .milliseconds(configuration.connectionRetryTimeoutMilliseconds)
            )
            let pool = RedisConnectionPool(configuration: poolConfiguration, boundEventLoop: group.next())
            candidatePool = pool
            pool.activate()
            _ = try await pool.ping().get()
            let topicValues = try await pool.send(command: "SMEMBERS", with: [RESPValue(from: topicsKey)]).get()
            guard let topics = topicValues.array else { throw RedisMessageBrokerError.invalidResponse }
            for value in topics {
                guard let topic = value.string else { throw RedisMessageBrokerError.invalidResponse }
                _ = try await execute(
                    pool,
                    script: Self.recoverProcessingScript,
                    keys: [processingKey(topic: topic), pendingKey(topic: topic), receiptsKey, processingCountKey(topic: topic)],
                    arguments: []
                )
            }
            self.eventLoopGroup = group
            self.pool = pool
            starting = false
        } catch {
            starting = false
            if let candidatePool { try? await Self.closePool(candidatePool) }
            try? await group.shutdownGracefully()
            throw error
        }
    }

    public func stop() async throws {
        guard let group = eventLoopGroup else { return }
        let pool = self.pool
        eventLoopGroup = nil
        self.pool = nil
        var failure: String?
        if let pool {
            do { try await Self.closePool(pool) }
            catch { failure = String(describing: error) }
        }
        do { try await group.shutdownGracefully() }
        catch { failure = [failure, String(describing: error)].compactMap { $0 }.joined(separator: "; ") }
        if let failure { throw RedisMessageBrokerError.shutdown(failure) }
    }

    @discardableResult
    public func publish(topic: String, payload: Data, idempotencyKey: String? = nil) async throws -> Bool {
        guard Self.isValidTopic(topic) else { throw RedisMessageBrokerError.invalidTopic }
        guard topic.utf8.count <= 256 else { throw RedisMessageBrokerError.topicTooLong(256) }
        if let idempotencyKey {
            guard !idempotencyKey.isEmpty else { throw RedisMessageBrokerError.invalidIdempotencyKey }
            guard idempotencyKey.utf8.count <= 256 else { throw RedisMessageBrokerError.idempotencyKeyTooLong(256) }
        }
        guard payload.count <= configuration.maximumPayloadBytes else {
            throw RedisMessageBrokerError.payloadTooLarge(configuration.maximumPayloadBytes)
        }
        let envelope = MessageEnvelope(topic: topic, payload: payload, idempotencyKey: idempotencyKey)
        let serialized = try Self.encoder.encode(RedisMessageRecord(envelope))
        let record = String(decoding: serialized, as: UTF8.self)
        let dedupe = idempotencyKey.map { idempotencyKeyRedisKey(topic: topic, key: $0) } ?? ""
        let response = try await execute(
            activePool(),
            script: Self.publishScript,
            keys: [pendingKey(topic: topic), processingCountKey(topic: topic), queuedBytesKey(topic: topic), topicsKey],
            arguments: [
                String(configuration.maximumMessagesPerTopic),
                String(payload.count),
                String(configuration.maximumQueuedBytesPerTopic),
                record,
                dedupe,
                String(configuration.deduplicationTTLMilliseconds),
                topic,
                String(configuration.maximumTopicCount)
            ]
        )
        guard let result = response.int else { throw RedisMessageBrokerError.invalidResponse }
        if result == 0 { return false }
        if result == -2 { throw RedisMessageBrokerError.topicLimitExceeded(configuration.maximumTopicCount) }
        if result < 0 { throw RedisMessageBrokerError.capacityExceeded }
        return true
    }

    public func receive(topic: String) async throws -> MessageEnvelope? {
        guard Self.isValidTopic(topic), topic.utf8.count <= 256 else {
            throw RedisMessageBrokerError.invalidTopic
        }
        let pool = try activePool()
        let response = try await execute(
            pool,
            script: Self.receiveScript,
            keys: [pendingKey(topic: topic), processingKey(topic: topic), processingCountKey(topic: topic), receiptsKey],
            arguments: []
        )
        guard let serialized = response.string else {
            if response.isNull { return nil }
            throw RedisMessageBrokerError.invalidResponse
        }
        let record = try Self.decoder.decode(RedisMessageRecord.self, from: Data(serialized.utf8))
        guard let message = record.envelope else { throw RedisMessageBrokerError.invalidResponse }
        return message
    }

    public func acknowledge(_ id: UUID) async throws {
        let pool = try activePool()
        guard let topic = try await pool.send(
            command: "HGET",
            with: [RESPValue(from: receiptsKey), RESPValue(from: id.uuidString)]
        ).get().string else {
            throw RedisMessageBrokerError.unknownDelivery(id)
        }
        let response = try await execute(pool, script: Self.acknowledgeScript,
            keys: [processingKey(topic: topic), processingCountKey(topic: topic), queuedBytesKey(topic: topic), receiptsKey],
            arguments: [id.uuidString])
        guard let result = response.int else { throw RedisMessageBrokerError.invalidResponse }
        guard result == 1 else { throw RedisMessageBrokerError.unknownDelivery(id) }
    }

    public func reject(_ id: UUID) async throws {
        let pool = try activePool()
        guard let topic = try await pool.send(
            command: "HGET",
            with: [RESPValue(from: receiptsKey), RESPValue(from: id.uuidString)]
        ).get().string else {
            throw RedisMessageBrokerError.unknownDelivery(id)
        }
        let attemptResponse = try await execute(
            pool,
            script: Self.deliveryAttemptScript,
            keys: [processingKey(topic: topic)],
            arguments: [id.uuidString]
        )
        guard let currentAttempt = attemptResponse.int, currentAttempt >= 0 else {
            throw RedisMessageBrokerError.unknownDelivery(id)
        }
        let nextAttempt = currentAttempt + 1
        if nextAttempt < configuration.maximumDeliveryAttempts {
            let multiplier = Int64(1) << min(max(0, nextAttempt - 1), 20)
            let base = configuration.retryBackoffMilliseconds
            let delay = base > configuration.maximumRetryBackoffMilliseconds / multiplier
                ? configuration.maximumRetryBackoffMilliseconds
                : base * multiplier
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
        }
        let response = try await execute(pool, script: Self.rejectScript,
            keys: [pendingKey(topic: topic), processingKey(topic: topic), processingCountKey(topic: topic), queuedBytesKey(topic: topic), deadLetterKey(topic: topic), deadLetterBytesKey(topic: topic), receiptsKey],
            arguments: [
                id.uuidString,
                String(configuration.maximumDeliveryAttempts),
                String(configuration.maximumDeadLetterMessages),
                String(configuration.maximumDeadLetterBytes)
            ])
        guard let result = response.int else { throw RedisMessageBrokerError.invalidResponse }
        guard result == -1 || result > 0 else { throw RedisMessageBrokerError.unknownDelivery(id) }
    }

    public func deadLetterMessages(topic: String) async throws -> [MessageEnvelope] {
        let values = try await activePool().send(
            command: "LRANGE",
            with: [RESPValue(from: deadLetterKey(topic: topic)), RESPValue(from: "0"), RESPValue(from: "-1")]
        ).get()
        guard let records = values.array else { throw RedisMessageBrokerError.invalidResponse }
        return try records.map { value in
            guard let serialized = value.string else { throw RedisMessageBrokerError.invalidResponse }
            let record = try Self.decoder.decode(RedisMessageRecord.self, from: Data(serialized.utf8))
            guard let envelope = record.envelope else { throw RedisMessageBrokerError.invalidResponse }
            return envelope
        }
    }

    public func queuedByteCount(topic: String) async throws -> Int {
        let response = try await activePool().send(command: "GET", with: [RESPValue(from: queuedBytesKey(topic: topic))]).get()
        guard let value = response.string else { return 0 }
        guard let count = Int(value) else { throw RedisMessageBrokerError.invalidResponse }
        return count
    }

    private func activePool() throws -> RedisConnectionPool {
        guard let pool else { throw RedisMessageBrokerError.notStarted }
        return pool
    }

    private func execute(
        _ pool: RedisConnectionPool,
        script: String,
        keys: [String],
        arguments: [String]
    ) async throws -> RESPValue {
        var values = [RESPValue(from: script), RESPValue(from: String(keys.count))]
        values.append(contentsOf: keys.map(RESPValue.init(from:)))
        values.append(contentsOf: arguments.map(RESPValue.init(from:)))
        return try await pool.send(command: "EVAL", with: values).get()
    }

    private var topicsKey: String { "\(configuration.keyPrefix):topics" }
    private var receiptsKey: String { "\(configuration.keyPrefix):receipts:\(configuration.consumerID)" }

    private func topicRoot(_ topic: String) -> String {
        "\(configuration.keyPrefix):topic:\(Self.encodeComponent(topic))"
    }

    private func pendingKey(topic: String) -> String { "\(topicRoot(topic)):pending" }
    private func processingKey(topic: String) -> String { "\(topicRoot(topic)):processing:\(configuration.consumerID)" }
    private func processingCountKey(topic: String) -> String { "\(topicRoot(topic)):processing-count" }
    private func queuedBytesKey(topic: String) -> String { "\(topicRoot(topic)):queued-bytes" }
    private func deadLetterKey(topic: String) -> String { "\(topicRoot(topic)):dead" }
    private func deadLetterBytesKey(topic: String) -> String { "\(topicRoot(topic)):dead-bytes" }
    private func idempotencyKeyRedisKey(topic: String, key: String) -> String {
        "\(topicRoot(topic)):dedupe:\(Self.encodeComponent(key))"
    }

    private static func isValidTopic(_ topic: String) -> Bool {
        !topic.isEmpty && topic == topic.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func encodeComponent(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func closePool(_ pool: RedisConnectionPool) async throws {
        let promise = pool.eventLoop.makePromise(of: Void.self)
        pool.close(promise: promise)
        try await promise.futureResult.get()
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}

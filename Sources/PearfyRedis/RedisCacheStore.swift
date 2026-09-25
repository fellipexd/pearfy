import Foundation
import NIOCore
import NIOPosix
import PearfyCache
import PearfyContext
@preconcurrency import RediStack

public struct RedisCacheConfiguration: Sendable {
    public let host: String
    public let port: Int
    public let username: String?
    public let password: String?
    public let database: Int
    public let keyPrefix: String
    public let maximumConnections: Int
    public let connectionRetryTimeoutMilliseconds: Int64
    public let maximumValueBytes: Int

    public init(
        host: String = "127.0.0.1",
        port: Int = 6379,
        username: String? = nil,
        password: String? = nil,
        database: Int = 0,
        keyPrefix: String = "pearfy",
        maximumConnections: Int = 8,
        connectionRetryTimeoutMilliseconds: Int64 = 5_000,
        maximumValueBytes: Int = 1_048_576
    ) throws {
        let validPrefix = !keyPrefix.isEmpty && keyPrefix.utf8.count <= 64 && keyPrefix.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
        guard !host.isEmpty, (1...65_535).contains(port), database >= 0, validPrefix,
              (1...512).contains(maximumConnections), connectionRetryTimeoutMilliseconds > 0,
              maximumValueBytes > 0, username?.isEmpty != true, password?.isEmpty != true,
              username == nil || password != nil
        else {
            throw RedisCacheError.invalidConfiguration
        }
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.keyPrefix = keyPrefix
        self.maximumConnections = maximumConnections
        self.connectionRetryTimeoutMilliseconds = connectionRetryTimeoutMilliseconds
        self.maximumValueBytes = maximumValueBytes
    }
}

public enum RedisCacheError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidConfiguration
    case notStarted
    case alreadyStarting
    case valueTooLarge(maximumBytes: Int)
    case shutdown(String)

    public var description: String {
        switch self {
        case .invalidConfiguration: "PEARFY_REDIS_001: invalid Redis cache configuration"
        case .notStarted: "PEARFY_REDIS_002: Redis cache has not started"
        case .alreadyStarting: "PEARFY_REDIS_003: Redis cache is already starting"
        case .valueTooLarge(let maximumBytes): "PEARFY_REDIS_004: Redis cache value exceeds \(maximumBytes) bytes"
        case .shutdown(let message): "PEARFY_REDIS_005: Redis cache shutdown failed: \(message)"
        }
    }
}

/// Redis-backed `CacheStore` using RediStack's bounded connection pool.
public actor RedisCacheStore: CacheStore, ApplicationLifecycle {
    public nonisolated let name = "Pearfy Redis cache"

    private let configuration: RedisCacheConfiguration
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var pool: RedisConnectionPool?
    private var starting = false

    public init(configuration: RedisCacheConfiguration) {
        self.configuration = configuration
    }

    public func start() async throws {
        guard pool == nil else { return }
        guard !starting else { throw RedisCacheError.alreadyStarting }
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
            self.eventLoopGroup = group
            self.pool = pool
            starting = false
        } catch {
            starting = false
            if let candidatePool { try? await closePool(candidatePool) }
            try? await group.shutdownGracefully()
            throw error
        }
    }

    public func stop() async throws {
        guard let group = eventLoopGroup else { return }
        let pool = self.pool
        self.eventLoopGroup = nil
        self.pool = nil

        var shutdownFailure: String?
        if let pool {
            do { try await closePool(pool) }
            catch { shutdownFailure = String(describing: error) }
        }
        do { try await group.shutdownGracefully() }
        catch { shutdownFailure = [shutdownFailure, String(describing: error)].compactMap { $0 }.joined(separator: "; ") }
        if let shutdownFailure { throw RedisCacheError.shutdown(shutdownFailure) }
    }

    public func set<Value: Codable & Sendable>(_ value: Value, for key: CacheKey, ttl: Duration? = nil) async throws {
        let data: Data
        do { data = try JSONEncoder().encode(value) }
        catch { throw CacheError.encodingFailure(String(reflecting: Value.self)) }
        guard data.count <= configuration.maximumValueBytes else {
            throw RedisCacheError.valueTooLarge(maximumBytes: configuration.maximumValueBytes)
        }
        let redisKey = RedisKey(storageKey(for: key))
        let encodedValue = data.base64EncodedString()
        let pool = try activePool()
        if let ttl {
            let accepted = try await pool.set(
                redisKey,
                to: encodedValue,
                onCondition: .none,
                expiration: .milliseconds(Self.expirationMilliseconds(ttl))
            ).map { $0 == .ok }.get()
            guard accepted else { throw RedisCacheError.notStarted }
        } else {
            try await pool.set(redisKey, to: encodedValue).get()
        }
    }

    public func value<Value: Decodable & Sendable>(for key: CacheKey, as type: Value.Type = Value.self) async throws -> Value? {
        let pool = try activePool()
        let redisKey = RedisKey(storageKey(for: key))
        guard let encodedValue = try await pool.get(redisKey, as: String.self).get(),
              let data = Data(base64Encoded: encodedValue) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public func remove(_ key: CacheKey) async throws {
        _ = try await activePool().delete([RedisKey(storageKey(for: key))]).get()
    }

    public func removeAll(namespace: String, tenant: String? = nil) async throws {
        _ = try CacheKey(namespace: namespace, tenant: tenant, value: "namespace-removal")
        let tenantComponent = tenant.map(Self.encodeComponent) ?? "-"
        let pattern = "\(configuration.keyPrefix):\(Self.encodeComponent(namespace)):\(tenantComponent):*"
        let pool = try activePool()
        var cursor = 0
        repeat {
            let page = try await pool.scan(startingFrom: cursor, matching: pattern, count: 128).get()
            cursor = page.0
            if !page.1.isEmpty {
                let keys = page.1.map { RedisKey($0) }
                _ = try await pool.delete(keys).get()
            }
        } while cursor != 0
    }

    private func activePool() throws -> RedisConnectionPool {
        guard let pool else { throw RedisCacheError.notStarted }
        return pool
    }

    private func closePool(_ pool: RedisConnectionPool) async throws {
        let promise = pool.eventLoop.makePromise(of: Void.self)
        pool.close(promise: promise)
        try await promise.futureResult.get()
    }

    private func storageKey(for key: CacheKey) -> String {
        let tenant = key.tenant.map(Self.encodeComponent) ?? "-"
        return "\(configuration.keyPrefix):\(Self.encodeComponent(key.namespace)):\(tenant):\(Self.encodeComponent(key.value))"
    }

    private static func encodeComponent(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func expirationMilliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return Int(max(1, min(Double(Int.max), ceil(milliseconds))))
    }
}

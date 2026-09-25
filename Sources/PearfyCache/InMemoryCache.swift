import Foundation
import PearfyObservability

public struct CacheKey: Hashable, Sendable {
    public let namespace: String
    public let tenant: String?
    public let value: String

    public init(namespace: String, tenant: String? = nil, value: String) throws {
        guard !namespace.isEmpty, !value.isEmpty, tenant?.isEmpty != true else {
            throw CacheError.invalidKey
        }
        guard namespace.utf8.count <= 256, (tenant?.utf8.count ?? 0) <= 256, value.utf8.count <= 1_024 else {
            throw CacheError.keyTooLarge(maximumBytes: 1_024)
        }
        self.namespace = namespace
        self.tenant = tenant
        self.value = value
    }

    fileprivate var storageKey: String {
        "\(namespace.utf8.count):\(namespace)|\(tenant?.utf8.count ?? 0):\(tenant ?? "")|\(value)"
    }
}

public enum CacheError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidKey
    case keyTooLarge(maximumBytes: Int)
    case encodingFailure(String)
    case entryTooLarge(maximumBytes: Int)

    public var description: String {
        switch self {
        case .invalidKey: "PEARFY_CACHE_001: namespace, tenant and value keys must not be empty"
        case .keyTooLarge(let maximumBytes): "PEARFY_CACHE_002: cache key exceeds \(maximumBytes) bytes"
        case .encodingFailure(let type): "PEARFY_CACHE_003: failed to encode cached value of type \(type)"
        case .entryTooLarge(let maximumBytes): "PEARFY_CACHE_004: encoded entry and key exceed cache byte limit of \(maximumBytes)"
        }
    }
}

public protocol CacheStore: Sendable {
    func set<Value: Codable & Sendable>(_ value: Value, for key: CacheKey, ttl: Duration?) async throws
    func value<Value: Decodable & Sendable>(for key: CacheKey, as type: Value.Type) async throws -> Value?
    func remove(_ key: CacheKey) async throws
    func removeAll(namespace: String, tenant: String?) async throws
}

/// Bounded memory cache with TTL, LRU eviction, and namespace/tenant key isolation.
public actor InMemoryCache: CacheStore {
    private struct Entry: Sendable {
        let data: Data
        let storageCost: Int
        let expiry: ContinuousClock.Instant?
        var lastAccess: UInt64
    }

    private let capacity: Int
    private let maximumBytes: Int
    private let metrics: MetricsRegistry?
    private let clock = ContinuousClock()
    private var entries: [String: Entry] = [:]
    private var accessSequence: UInt64 = 0
    private var storedBytes = 0

    public init(
        capacity: Int = 1_024,
        maximumBytes: Int = 64 * 1_024 * 1_024,
        metrics: MetricsRegistry? = nil
    ) {
        self.capacity = max(1, capacity)
        self.maximumBytes = max(1, maximumBytes)
        self.metrics = metrics
    }

    public func set<Value: Codable & Sendable>(_ value: Value, for key: CacheKey, ttl: Duration? = nil) async throws {
        _ = purgeExpired()
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw CacheError.encodingFailure(String(reflecting: Value.self))
        }
        let keyBytes = key.storageKey.utf8.count
        guard keyBytes <= maximumBytes, data.count <= maximumBytes - keyBytes else {
            throw CacheError.entryTooLarge(maximumBytes: maximumBytes)
        }
        let storageCost = data.count + keyBytes

        accessSequence &+= 1
        let expiry = ttl.map { clock.now.advanced(by: max(.zero, $0)) }
        if let previous = entries[key.storageKey] { storedBytes -= previous.storageCost }
        entries[key.storageKey] = Entry(data: data, storageCost: storageCost, expiry: expiry, lastAccess: accessSequence)
        storedBytes += storageCost
        let evictions = evictIfNeeded()
        await publishStateMetrics()
        if evictions > 0 { try? await metrics?.increment("pearfy_cache_evictions_total", by: UInt64(evictions)) }
    }

    public func value<Value: Decodable & Sendable>(for key: CacheKey, as type: Value.Type = Value.self) async throws -> Value? {
        let expired = purgeExpired()
        guard var entry = entries[key.storageKey] else {
            try? await metrics?.increment("pearfy_cache_misses_total")
            if expired > 0 { await publishStateMetrics() }
            return nil
        }
        accessSequence &+= 1
        entry.lastAccess = accessSequence
        entries[key.storageKey] = entry
        do {
            let value = try JSONDecoder().decode(type, from: entry.data)
            try? await metrics?.increment("pearfy_cache_hits_total")
            if expired > 0 { await publishStateMetrics() }
            return value
        } catch {
            try? await metrics?.increment("pearfy_cache_misses_total")
            if expired > 0 { await publishStateMetrics() }
            return nil
        }
    }

    public func remove(_ key: CacheKey) async throws {
        if let removed = entries.removeValue(forKey: key.storageKey) {
            storedBytes -= removed.storageCost
            await publishStateMetrics()
        }
    }

    public func removeAll(namespace: String, tenant: String? = nil) async throws {
        let prefix = "\(namespace.utf8.count):\(namespace)|\(tenant?.utf8.count ?? 0):\(tenant ?? "")|"
        let removedKeys = entries.keys.filter { $0.hasPrefix(prefix) }
        for key in removedKeys { removeStorageKey(key) }
        if !removedKeys.isEmpty { await publishStateMetrics() }
    }

    public func count() async -> Int {
        let expired = purgeExpired()
        if expired > 0 { await publishStateMetrics() }
        return entries.count
    }

    public func byteCount() async -> Int {
        let expired = purgeExpired()
        if expired > 0 { await publishStateMetrics() }
        return storedBytes
    }

    private func purgeExpired() -> Int {
        let now = clock.now
        let expiredKeys = entries.compactMap { key, entry -> String? in
            guard let expiry = entry.expiry, expiry <= now else { return nil }
            return key
        }
        for key in expiredKeys { removeStorageKey(key) }
        return expiredKeys.count
    }

    private func evictIfNeeded() -> Int {
        var evictions = 0
        while (entries.count > capacity || storedBytes > maximumBytes),
              let leastRecentlyUsed = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            removeStorageKey(leastRecentlyUsed)
            evictions += 1
        }
        return evictions
    }

    private func removeStorageKey(_ key: String) {
        if let removed = entries.removeValue(forKey: key) { storedBytes -= removed.storageCost }
    }

    private func publishStateMetrics() async {
        guard let metrics else { return }
        try? await metrics.setGauges([
            "pearfy_cache_entries": Double(entries.count),
            "pearfy_cache_storage_bytes": Double(storedBytes)
        ])
    }
}

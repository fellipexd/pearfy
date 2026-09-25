import PearfyCache
import PearfyObservability
import Testing

@Test func cacheIsolatesNamespacesTenantsAndEvictsLeastRecentlyUsed() async throws {
    let cache = InMemoryCache(capacity: 2)
    let shared = try CacheKey(namespace: "users", tenant: "a", value: "1")
    let otherTenant = try CacheKey(namespace: "users", tenant: "b", value: "1")
    let anotherNamespace = try CacheKey(namespace: "sessions", tenant: "a", value: "1")

    try await cache.set("tenant-a", for: shared)
    try await cache.set("tenant-b", for: otherTenant)
    #expect(try await cache.value(for: shared, as: String.self) == "tenant-a")
    try await cache.set("session", for: anotherNamespace)

    #expect(await cache.count() == 2)
    #expect(try await cache.value(for: shared, as: String.self) == "tenant-a")
    #expect(try await cache.value(for: otherTenant, as: String.self) == nil)
    #expect(try await cache.value(for: anotherNamespace, as: String.self) == "session")
}

@Test func cacheExpiresEntriesAndCanEvictOneTenantNamespace() async throws {
    let cache = InMemoryCache(capacity: 4)
    let short = try CacheKey(namespace: "tokens", tenant: "one", value: "short")
    let long = try CacheKey(namespace: "tokens", tenant: "two", value: "long")
    try await cache.set("short", for: short, ttl: .milliseconds(10))
    try await cache.set("long", for: long)
    try await Task.sleep(for: .milliseconds(20))

    #expect(try await cache.value(for: short, as: String.self) == nil)
    #expect(try await cache.value(for: long, as: String.self) == "long")
    try await cache.removeAll(namespace: "tokens", tenant: "two")
    #expect(await cache.count() == 0)
}

@Test func cacheBoundsTotalEncodedBytes() async throws {
    let cache = InMemoryCache(capacity: 10, maximumBytes: 80)
    let first = try CacheKey(namespace: "bytes", value: "first")
    let second = try CacheKey(namespace: "bytes", value: "second")
    let tooLarge = try CacheKey(namespace: "bytes", value: "large")
    try await cache.set("abc", for: first)
    try await cache.set("def", for: second)
    #expect(await cache.byteCount() <= 80)

    var rejected = false
    do {
        try await cache.set(String(repeating: "x", count: 100), for: tooLarge)
    } catch CacheError.entryTooLarge(maximumBytes: 80) {
        rejected = true
    }
    #expect(rejected)
    #expect(await cache.byteCount() <= 80)
}

@Test func cacheRejectsUnboundedKeyComponents() throws {
    var rejected = false
    do {
        _ = try CacheKey(namespace: "keys", value: String(repeating: "x", count: 1_025))
    } catch CacheError.keyTooLarge(maximumBytes: 1_024) {
        rejected = true
    }
    #expect(rejected)
}

@Test func cachePublishesBoundedHitMissEvictionAndStorageMetrics() async throws {
    let metrics = MetricsRegistry()
    let cache = InMemoryCache(capacity: 1, metrics: metrics)
    let first = try CacheKey(namespace: "metrics", value: "first")
    let missing = try CacheKey(namespace: "metrics", value: "missing")
    let second = try CacheKey(namespace: "metrics", value: "second")

    try await cache.set("one", for: first)
    #expect(try await cache.value(for: first, as: String.self) == "one")
    #expect(try await cache.value(for: missing, as: String.self) == nil)
    try await cache.set("two", for: second)

    let output = await metrics.prometheusText()
    #expect(output.contains("pearfy_cache_hits_total 1"))
    #expect(output.contains("pearfy_cache_misses_total 1"))
    #expect(output.contains("pearfy_cache_evictions_total 1"))
    #expect(output.contains("pearfy_cache_entries 1.0"))
    #expect(output.contains("pearfy_cache_storage_bytes "))
}

# Redis adapter reference

- `RedisCacheStore.swift` implements the cache adapter; `RedisMessageBroker.swift` implements the broker adapter.
- Package products and transitive requirements are in the module registry. Add via `pearfy add redis`; this selects required cache/messaging products in managed projects.
- Inspect constructor settings in source; do not assume configuration environment variable names or TLS defaults not present in code.
- Integration tests require configured Redis service variables. Unit mocks do not prove cross-process server behavior.
- Redis and PostgreSQL do not share a physical transaction in this checkout.

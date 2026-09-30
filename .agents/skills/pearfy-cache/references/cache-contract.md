# Cache behavior

- The current in-memory implementation is in `Sources/PearfyCache/InMemoryCache.swift`.
- Namespace/tenant boundaries, expiry and encoded-size/cardinality bounds are part of the tested contract.
- `PearfyRedis` supplies a separate distributed adapter. Its availability does not make in-memory cache state shared.
- Do not use cache as the authorization source or as durable state. Apply app-level ownership before populating/read-through.
- Relevant validation includes expiry, isolation, eviction, hit/miss and total encoded-byte limits.

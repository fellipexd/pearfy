# In-memory delivery semantics

- Source: `Sources/PearfyMessaging/InMemoryBroker.swift`.
- Capacity and queued payload bytes are bounded. Full queues reject/hold according to the current operation contract; inspect code before relying on blocking behavior.
- Acknowledgement, retry and dead-letter behavior are explicit. Process restart loses in-memory state.
- Idempotency keys reduce duplicate application effects only within the broker's configured scope/window; they do not replace database constraints.
- Redis-backed broker behavior lives in `Sources/PearfyRedis/RedisMessageBroker.swift` and is a separate opt-in product.

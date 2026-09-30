# Social graph adapter boundary

- Source: `Sources/PearfySocialPostgres/PostgresSocialGraphStore.swift`.
- Adapter dependencies are `PearfySocial`, `PearfyData`, `PearfyPostgres`, PostgresNIO and Crypto.
- Existing operations concern actors and graph edges/policies. Inspect the concrete store protocol before extending table coverage.
- Tests requiring PostgreSQL are conditional on `PEARFY_TEST_POSTGRES_*`; an unconfigured run is not database validation.
- Content persistence/outbox is not implemented. Do not claim atomic post + event delivery.

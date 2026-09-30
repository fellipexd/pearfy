# Outbound HTTP reference

- `HTTPClient` and `HTTPConcurrencyLimiter` define current API and admission behavior.
- A request may be rejected when active and queued limits are reached; cancellation must release capacity.
- Circuit breaker and retry policy are independent state/attempt controls. Review method idempotency before applying a retry policy.
- Use explicit transports in tests; tests with a stub do not certify DNS, TLS, provider quotas or remote uptime.
- Keep base URLs and credentials in configuration/secret providers, not Skill files or contracts.

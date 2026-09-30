# Logs with Observability

**Status: planned structured logging.** `PearfyObservability` implements health/readiness and Prometheus metrics, not `PearfyLogs`, structured log export or OTLP.

Do not invent logging APIs. If the application adds its own logger, redact credentials, cookies, bodies, bindings and personal data before export. Revisit when a concrete PearfyLogs package, configuration contract and tests are registered.

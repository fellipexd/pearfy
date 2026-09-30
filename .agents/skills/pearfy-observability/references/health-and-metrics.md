# Health and metrics reference

- `HealthRegistry` stores bounded named async probes; `ReadinessGate` models starting/ready/draining/stopped.
- `MetricsRegistry` bounds series/labels and supports counter, gauge and histogram types. Review bucket semantics before deriving quantiles.
- `HTTPMetricsMiddleware` records method, registered route template and status class; it does not record request bodies.
- `HealthRoutes.install` exposes liveness/readiness and optionally a protected Prometheus endpoint.
- There is no PearfyLogs exporter, distributed trace collector or high-level PearfyMetric analytics in this checkout.

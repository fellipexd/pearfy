---
name: pearfy-observability
description: Use for health/readiness, Prometheus metrics, HTTP telemetry, and observable runtime boundaries.
metadata:
  pearfy-module: observability
  pearfy-skill-version: 1.0.0
---

# Pearfy observability

Use for the current health and metrics primitives. Confirm the module in `pearfy ai inspect`; read `references/health-and-metrics.md` and inspect `Sources/PearfyObservability/`.

## Current capabilities

The module provides health checks, readiness and a bounded metrics registry with counters, gauges, histograms and HTTP middleware. `PearfyDevKitUI` can consume an allowlisted subset when explicitly installed. Structured logs, distributed tracing and PearfyMetric analytics are not implemented.

## Safety

Use low-cardinality route templates and safe labels. Never put credentials, request bodies, SQL bindings or customer values in metric labels. A histogram bucket-derived percentile is approximate and cumulative counters are not a time window.

## Validate

Run `swift build` and `bash scripts/test-unit.sh`. Use the existing observability tests and measure instrumentation overhead with the declared benchmark before changing request-path work.

---
name: pearfy-cloud
description: Use for outbound HTTP clients, concurrency limits, queue bounds, retries, and circuit breaker policies.
metadata:
  pearfy-module: cloud
  pearfy-skill-version: 1.0.0
---

# Pearfy outbound HTTP

Load when an application calls an external HTTP service. Check installed products with `pearfy ai inspect`; inspect `Sources/PearfyCloud/HTTPClient.swift` and `HTTPConcurrencyLimiter.swift`.

## Available contracts

The module provides bounded concurrency/queue behavior and resilience policy types used by the HTTP client. Read `references/http-client.md` before changing retries, cancellation or transport injection.

## Restrictions and integration

Retry only idempotent requests or operations with an explicit idempotency contract. Bound attempts, queued work and response payloads. Do not log authorization headers, request bodies or provider errors containing secrets. `pearfy-ai` is a separate application client layered above this HTTP module.

## Validate

Run `swift build` and `bash scripts/test-unit.sh`; use the controlled test transport for cancellation, queue saturation, retries and circuit state. Do not claim remote-provider reliability from stub tests.

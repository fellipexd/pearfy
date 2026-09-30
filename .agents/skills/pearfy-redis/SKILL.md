---
name: pearfy-redis
description: Use for Redis-backed cache and message broker adapters, connection behavior, and Redis integration tests.
metadata:
  pearfy-module: redis
  pearfy-skill-version: 1.0.0
---

# Pearfy Redis adapters

Load with `pearfy-cache` or `pearfy-messaging` only when shared Redis-backed behavior is needed. Confirm the module is installed and service configuration is known using `pearfy ai inspect`.

## Current behavior

The `PearfyRedis` product contains cache and message broker adapters. Read `references/adapters.md` and inspect `Sources/PearfyRedis/` before relying on a delivery or expiration guarantee.

## Restrictions

Redis is an external service, not bundled storage. Do not equate Redis persistence settings with a transactional database, durable outbox or exactly-once delivery. Keep credentials out of source and AI output. If atomic application data plus message delivery is required, use only an implemented database transaction/outbox contract; do not assume one is available.

## Validate

Run `swift build` and `bash scripts/test-unit.sh`. Run `bash scripts/test-integrations.sh` with explicit local Redis configuration for adapter behavior; missing service means not verified.

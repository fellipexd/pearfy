---
name: pearfy-messaging
description: Use for bounded in-memory broker topics, acknowledgements, retries, dead letters, and delivery semantics.
metadata:
  pearfy-module: messaging
  pearfy-skill-version: 1.0.0
---

# Pearfy messaging

Use when changing the broker or message consumer contracts. Check whether the project selected `messaging` or the separate `redis` adapter using `pearfy ai inspect`.

## Current implementation

`PearfyMessaging` has a bounded in-memory broker with acknowledgement, retry, dead-letter and idempotency behavior. Read `references/delivery-contract.md` and inspect `Sources/PearfyMessaging/InMemoryBroker.swift`.

## Safety and integration

In-memory queued data does not survive process restart and is not shared across replicas. Do not claim durable delivery or exactly-once processing. Design handlers to be idempotent and keep payload limits. Select `redis` only when Redis behavior and service configuration are appropriate. No durable database outbox is included.

## Validate

Run `swift build` and `bash scripts/test-unit.sh`; cover capacity, queued-byte limits, retries, acknowledgements and shutdown for changed behavior.

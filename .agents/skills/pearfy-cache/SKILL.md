---
name: pearfy-cache
description: Use for bounded in-memory cache behavior, TTL, namespaces, eviction, and cache adapter selection.
metadata:
  pearfy-module: cache
  pearfy-skill-version: 1.0.0
---

# Pearfy cache

Use for local cache contracts or behavior. Verify the selected `cache` module and actual product version with `pearfy ai inspect`.

## Current capabilities

`PearfyCache` provides bounded in-memory storage, expiry, namespace/tenant isolation, eviction and metrics. Read `references/cache-contract.md` and inspect `Sources/PearfyCache/InMemoryCache.swift`. `redis` is a separate adapter and must be selected explicitly for shared/persistent behavior.

## Restrictions

An in-memory cache is process-local and is not a source of durable truth. Keep keys and values bounded; avoid secrets or personal data unless the application has an explicit retention and authorization policy. Do not claim cross-replica invalidation for local entries.

## Integrations and validation

Load `pearfy-redis` only for Redis adapter work. Run `swift build` and `bash scripts/test-unit.sh`; test byte limits, TTL, tenant isolation and eviction for behavior changes.

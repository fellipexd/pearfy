---
name: pearfy-social-postgres
description: Use when persisting PearfySocial graph actors, follows, blocks, or visibility policies in PostgreSQL.
metadata:
  pearfy-module: social-postgres
  pearfy-skill-version: 1.0.0
---

# Pearfy Social PostgreSQL adapter

Load together with `pearfy-social` when a task changes the durable graph adapter. The current registry maps `social-postgres` to `PearfySocialPostgres`; verify the selected version and dependencies with `pearfy ai inspect`.

## Current boundary

The adapter persists graph operations against PostgreSQL and enforces actor ownership/visibility rules covered by its integration tests. Read `references/storage-boundary.md` and inspect `Sources/PearfySocialPostgres/PostgresSocialGraphStore.swift`.

## Restrictions and validation

It does not persist social posts, comments, feeds, media or notification outbox records. Do not add SQL in the protocol layer; use `pearfy-data` and `pearfy-postgres` for database-level work. Keep idempotency and visibility checks inside the transaction. Run `swift build`, `bash scripts/test-unit.sh`, and configured PostgreSQL integration tests for changed queries.

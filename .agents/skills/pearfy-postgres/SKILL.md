---
name: pearfy-postgres
description: Use for PostgreSQL connections, query execution, transaction integration, and migration runner changes.
metadata:
  pearfy-module: postgres
  pearfy-skill-version: 1.0.0
---

# Pearfy PostgreSQL

Use for the concrete PostgreSQL adapter. Confirm that `postgres` is installed with `pearfy ai inspect`; its dependency graph includes `data` and `transactions`.

## Current capabilities

The adapter provides validated connection settings, parameterized execution, transaction integration and versioned migration application/planning. Read `references/connection-and-migrations.md`; inspect `Sources/PearfyPostgres/` and the integration tests.

## Safety and integration

Keep SQL values bound and identifiers validated. Schema application is versioned and checksum-aware; destructive changes need the explicit compiler/runner approval flow. Do not assume support for an arbitrary database driver, migration rollback or schema feature without checking its code and tests. Local integration tests require explicitly configured PostgreSQL service variables.

## Validate

Run `swift build` and `bash scripts/test-unit.sh`. Run `bash scripts/test-integrations.sh` only with the local PostgreSQL/Redis services required by the selected tests. Guardian must report missing integration configuration as INCOMPLETE, not PASS.

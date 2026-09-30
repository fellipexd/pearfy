---
name: pearfy-data
description: Use for typed SQL, schema IR, PostgreSQL schema changes, migrations, and data-layer safety.
metadata:
  pearfy-module: data
  pearfy-skill-version: 1.0.0
---

# Pearfy data

Use when changing persistence models, SQL, schema descriptions, or migration plans. Check `pearfy ai inspect` and `pearfy modules info data` for the current checkout before relying on a roadmap feature.

## Prerequisites and current capabilities

The available `data` product provides parameterized SQL builders, `SchemaIR`, PostgreSQL DDL planning, identifiers and migration catalog contracts. PostgreSQL execution lives in the separate `postgres` module. Read `references/schema-and-sql.md`; inspect `Sources/PearfyData/SQLQuery.swift`, `SchemaCompiler.swift`, `SQLMigrationCatalog.swift`, and the corresponding tests.

## Integration and safety

Use bound values for all user input; validate identifiers with Pearfy types. Keep schema changes deterministic and versioned. Destructive changes require explicit approval. For physical transaction semantics, load `pearfy-transactions`; for a running database adapter load `pearfy-postgres`. The current layer is not a complete ORM and does not implement every migration lifecycle feature. Never claim a planned API exists because it appears in a roadmap.

## Validate

Run `swift build` and `bash scripts/test-unit.sh`; run PostgreSQL integration tests only when the local test services are configured. `pearfy guardian verify` provides its declared build/test/environment scope independently.

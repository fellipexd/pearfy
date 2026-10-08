---
name: pearfy-data
description: Use for typed SQL, schema IR, PostgreSQL schema changes, migrations, and data-layer safety.
metadata:
  pearfy-module: data
  pearfy-skill-version: 1.1.0
---

# Pearfy data

Use when changing persistence models, SQL, schema descriptions, or migration plans. Check `pearfy ai inspect` and `pearfy modules info data` for the current checkout before relying on a roadmap feature.

## Prerequisites and current capabilities

The available `data` product provides parameterized SQL builders, `SchemaIR`, PostgreSQL DDL planning, identifiers and migration catalog contracts. PostgreSQL execution lives in the separate `postgres` module. Read `references/schema-and-sql.md`; inspect `Sources/PearfyData/SQLQuery.swift`, `SchemaCompiler.swift`, `SQLMigrationCatalog.swift`, and the corresponding tests.

## Integration and safety

Prefer `@Entity`, `@ID`, and `@Column` when a Pearfy schema model has explicit stored fields and types supported by the current macro. The macro contributes `SchemaEntity` metadata; it is not an ORM and does not replace a repository or persistence adapter. Keep fields that need unsupported mappings in reviewed low-level `SchemaEntity` construction and record why the macro does not apply. Use bound values for all user input; validate identifiers with Pearfy types. Keep schema changes deterministic and versioned. Destructive changes require explicit approval. For physical transaction semantics, load `pearfy-transactions`; for a running database adapter load `pearfy-postgres`. Never claim a planned API exists because it appears in a roadmap.

In a project with no declared architecture style, follow Clean Architecture: keep schema entities and database adapters in Infrastructure, expose persistence through application/domain repository contracts, and use `@Repository` only on a real adapter with the matching semantics. `@Entity` describes supported persistence schema metadata; it is not a generic domain model or ORM. Preserve an explicitly declared architecture style.

## Validate

Run `swift build` and `bash scripts/test-unit.sh`; run PostgreSQL integration tests only when the local test services are configured. `pearfy guardian verify` provides its declared build/test/environment scope independently.

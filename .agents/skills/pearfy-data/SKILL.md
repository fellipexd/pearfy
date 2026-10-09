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

Prefer `@Entity`, `@ID`, and `@Column` for supported persisted schema models. When a persisted entity has an object or collection association, use the matching public relationship macro by default: `@ManyToOne` owns an FK; `@OneToOne` owns a unique FK or uses `mappedBy` on its inverse side; `@OneToMany` is inverse and maps to an owning `@ManyToOne`; `@ManyToMany` owns a junction table or uses `mappedBy` on the inverse side. `SchemaIR` resolves the metadata and materializes columns, constraints, or junction tables for the DDL planner. Unsupported object properties are not scalar columns: keep unsupported schema mappings in reviewed low-level `SchemaEntity` construction and record the concrete reason. Do not insert fake relationships in applications without persisted associations. The macros describe schema only; repositories/adapters still own reads, writes, and loading. Use bound values for all user input; validate identifiers with Pearfy types. Keep schema changes deterministic and versioned. Destructive changes require explicit approval. For physical transaction semantics, load `pearfy-transactions`; for a running database adapter load `pearfy-postgres`. Never claim a planned API exists because it appears in a roadmap.

In a project with no declared architecture style, follow Clean Architecture: keep schema entities and database adapters in Infrastructure, expose persistence through application/domain repository contracts, and use `@Repository` only on a real adapter with the matching semantics. `@Entity` describes supported persistence schema metadata; it is not a generic domain model or ORM. Preserve an explicitly declared architecture style.

## Validate

Run `swift build` and `bash scripts/test-unit.sh`; run PostgreSQL integration tests only when the local test services are configured. `pearfy guardian verify` provides its declared build/test/environment scope independently.

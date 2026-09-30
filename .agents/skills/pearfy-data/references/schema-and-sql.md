# Schema and SQL contracts

- `SQLQuery` builders preserve bindings; compose values as parameters and identifiers through `SQLIdentifier`.
- `SchemaIR` is canonicalized and fingerprinted. Entity/table/column/index validation is performed when constructing it.
- `PostgresSchemaCompiler` generates an initial deterministic plan. Unsupported alterations fail instead of silently guessing destructive semantics.
- `SQLMigrationCatalog` and `SQLMigrationRunner` live in data/PostgreSQL modules; inspect both before changing migration behavior. Applied artifact checksums and transaction locking are actual contracts; rollback automation is not.
- Model macros describe schema metadata only where the discovery plugin emits it for the target.

Source of truth: `Sources/PearfyData/`, `Sources/PearfyPostgres/`, `Tests/PearfyCoreTests/SchemaCompilerTests.swift`, `MigrationRunnerTests.swift`.

# PostgreSQL adapter reference

- With `--product`, `--model` is the destination path for the app's exported SchemaIR JSON; without `--product`, it is the input model file.

- Connection configuration is represented by `PostgresConnectionSettings`; inspect its accepted TLS, pool and timeout values in source before editing deployment config.
- `PostgresDatabase` owns the concrete PostgresNIO query and physical transaction boundary. Keep the dependency within the adapter.
- Migration artifacts/catalogs validate identifiers, parameters, checksum drift and execution state. Run `pearfy migrations generate --product <SwiftPM-product> --id <version_name> --output Migrations`; the app product must implement `--pearfy-export-schema <path>` by canonicalizing `PearfyGeneratedSchemaRegistry.entities` (`SchemaEntity` values) to SchemaIR JSON. Alternatively pass the emitted file with `--model`. Relationship metadata is resolved before PostgreSQL DDL is planned; this command does not connect to a database. `--replace-catalog` explicitly replaces an existing catalog after validating it.
- `pearfy migrations apply --environment local [--directory Migrations]` applies a generated catalog to a fresh local database; when it detects the legacy Java version ledger at the catalog baseline, it leaves that database untouched.
- `pearfy migrations import-java --source <directory> [--output Migrations]` remains a legacy conversion utility; application migrations should be generated from Pearfy models.
- The current test suite exercises real PostgreSQL only when `PEARFY_TEST_POSTGRES_*` variables are set. Unit/stub tests do not certify a live server.
- Never emit connection strings, credentials, SQL bindings or row dumps in MCP, logs or AI context.

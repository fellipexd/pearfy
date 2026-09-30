# Transaction boundary

- `PearfyTransactionManager` coordinates a `PearfyTransactionalStore` unit; verify exact method names in `TransactionManager.swift` before adding integrations.
- REQUIRED nested work reuses the ambient unit. A caught nested failure can mark that unit rollback-only.
- Cancellation must roll back a cooperative active unit. A commit-unknown result means the caller cannot assume either committed or rolled back.
- PostgreSQL transaction ownership is implemented in `Sources/PearfyPostgres/`; compare its integration tests before making claims about retries or cross-request behavior.
- No atomic transaction spans Redis, a remote HTTP service, or another independent database.

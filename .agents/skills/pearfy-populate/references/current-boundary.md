# PearfyPopulate executor boundary

- Current source of truth: `Sources/PearfyPopulateCore/`, `Sources/PearfyPopulatePostgres/`, `Sources/PearfyPopulateCLI/`, and `docs/PEARFY-POPULATE.md`.
- One target table per plan; one simple UUID/integer primary key or bounded text key (at least 32 characters); text keys are deterministic per plan and row ordinal. Other scalar values and eligible existing FK parents are generated within declared bounds.
- Plans are deterministic and hash-bound. Executor batches are bounded and resumable; committed batches remain committed after a later failure.
- Triggers, RLS, partitions, unsupported checks/indexes, FK cycles and missing required parents fail closed.
- No parent creation, DDL, COPY, cleanup, or broad deletes. Read-only profile emits aggregate shape only.
- `pearfy populate approve` is an interactive, human-only local CLI flow; its output must not be captured or relayed through an AI session. MCP exposes inspection and bounded local planning only; it has no database-write tool and accepts no approval tokens.

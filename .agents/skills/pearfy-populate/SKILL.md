---
name: pearfy-populate
description: Plans and executes synthetic, relational PostgreSQL data generation with schema checks, bounded runs, and local-data protections.
metadata:
  pearfy-module: populate
  pearfy-skill-version: 1.0.0
---

# PearfyPopulate

Use for synthetic test data or development/staging database load. Confirm the installed module version and PostgreSQL capabilities; documentation alone is not evidence that a capability exists.

## Required workflow

1. Run `pearfy populate inspect --environment local` and review database identity, schema fingerprint, constraints, triggers, migrations, and table names. Do not request or export row dumps.
2. If a model schema is maintained, store its `SchemaIR` JSON in `.pearfy/schema.json`; keep applied migration artifacts in `Migrations/` or `.pearfy/migrations/`. Resolve drift before planning.
3. Optional profiling is read-only and aggregate-only: `pearfy populate profile --table <table> --environment local --sample-local`. Never expose raw values, names, email addresses, message bodies, tokens, or payment data.
4. Create a bounded plan with a deterministic seed: `pearfy populate plan --table <table> --rows 100 --seed 42 --environment local`, or use `--target-size 2GB --size-mode total`.
5. Review `pearfy populate preview --plan <plan.json>`. Check table dependencies, unique/FK/check constraints, local disk headroom, target meaning, row/time/batch limits, and the exact plan hash.
6. Execute only through the local CLI with the explicit environment and matching approval hash: `pearfy populate run --plan <plan.json> --environment local --approve-plan-hash <plan-hash>`. MCP is limited to inspection and bounded local plan operations; it has no database-write tool and accepts no approval tokens. Do not invoke `pearfy populate approve` on the user's behalf; if they choose that optional token flow, they must run it in a private local terminal and keep its output out of MCP and model context.
7. Check `status`, `verify`, and `report`. A partial batch is reported honestly; already committed batches remain committed. Resume by rerunning the same plan and approval.

## Invariants

- Default to local synthetic data. Staging needs the explicit `PEARFY_POPULATE_ALLOW_STAGING=1` opt-in. Production-like host/database names are refused.
- Never disable PK, FK, UNIQUE, CHECK, triggers, RLS, WAL, or fsync. Never run DDL or migrations as part of population.
- Do not populate ledgers, financial state, administrative identity, audit, or external-notification tables with generic random SQL.
- External triggers cause the current PostgreSQL executor to fail closed. Use an isolated database and test adapters for side effects.
- FK values are selected only from eligible existing parents. Missing required parents and FK cycles are errors; do not silently invent parents or defer constraints.
- MCP exposes no database-write tool and accepts no approval tokens or arbitrary SQL. Approval tokens are human-only local CLI output; never request, capture, or relay them through an AI session. Database writes remain behind the direct local CLI approval flow.
- Local profiles return aggregate shape statistics only and execute in a read-only transaction. No row samples are sent to an LLM.
- `2GB` means an absolute final size target. The executor records the measured PostgreSQL relation size and can stop short at hard row/time/disk bounds.
- Cleanup is not available until ownership is proven. Never issue broad DELETE statements for a population run.
- Load `references/current-boundary.md` for the exact implemented executor limits; inspect `pearfy ai inspect` for the installed module version before following this Skill.

For the exact executor boundary and rejected PostgreSQL features, load `references/current-boundary.md` before planning a run.

# Skills-first context measurements

The available model/client interfaces do not expose a trustworthy per-task count of Skills loaded, prompt tokens or correction loops. This repository does not send equivalent tasks to an LLM as part of tests and does not claim token savings.

## Reproducible local indicators

```bash
python3 scripts/measure-ai-context.py --root .
pearfy ai inspect --scenarios
pearfy ai mcp list
```

The script reports Registry entry/status counts, Skill Markdown bytes, installed Skill bytes, selected modules and effective project MCP tool definitions. Six scenario rows cover a REST route, entity/migration, Social comment, TypeScript SDK, Populate plan and slow-route diagnosis. Counts use actual Registry Skills/references; unavailable APIs are marked planned. Byte totals include Skill/reference files, not tokens or implicit model context.

For a real client-run experiment, capture client token statistics and user-approved completion/correction outcomes for the same task/version, record the Skills actually opened and MCP calls, and compare the same test acceptance criteria. Do not include provider credentials, customer data or resolved config dumps in the measurement report.

## Observed baseline and current outcome

At inspection before this migration, the checkout had one project Skill (`pearfy-populate`), the MCP server statically listed 12 tools and the global OpenCode configuration enabled the Pearfy MCP server. The installed OpenCode version was 1.18.32. After migration, the current framework workspace's Package products infer 18 available Skills across 18 installable modules and 13 planned entries. Canonical Skill/reference Markdown totals **39,295 bytes**. The project-level OpenCode overlay resolves `pearfy.enabled=false`, so the tools actually exposed are **0** by default; explicitly granting Populate yields **7** bounded inspection/planning tools and no database-write tool.

Measured task selections in this checkout (`pearfy ai inspect --scenarios`):

| Equivalent task | Skills selected | Skill + reference bytes | Availability note |
|---|---:|---:|---|
| Create a REST route | 1 | 3,460 | Implemented route/controller contracts |
| Entity and migration | 3 | 6,729 | No full ORM; inspect migration plan/approval |
| Social comments | 3 | 6,285 | Durable content/feed PostgreSQL store absent |
| TypeScript SDK | 1 | 2,134 | Connect SDK generator unavailable |
| Populate plan | 1 | 4,749 | Single-target bounded executor; writes stay in the local CLI approval flow |
| Slow-route investigation | 2 | 5,277 | PearfyMetric/logs/traces unavailable; `metric` is planned |

These are selected-file byte counts, not estimates of tokenizer output or total implicit client prompt size. `opencode debug skill` listed 18 Pearfy Skills and 1 built-in Skill in this full framework workspace; it does not tell us which bodies a later task opened. MCP calls per task and LLM completion/correction quality remain unmeasured because no repeatable model-client telemetry was available and no LLM was invoked. Unit/integration regression tests validate the implementation instead; they are not a substitute for future task-level quality experiments.

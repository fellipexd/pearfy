# Guardian under Skills-first

Skills and MCP provide guidance/data; Guardian is the independent deterministic gate. Its result comes from actual command execution and cannot be supplied by an agent's assertion.

## Current verified scope

`pearfy guardian verify` in this checkout runs `swift build`, `bash scripts/test-unit.sh`, and checks test-declared service environment variables. It returns PASS/FAIL/INCOMPLETE for that scope. It does **not** currently certify SQL/migration policy, security policy, contract compatibility, external SDK generation, release, or runtime telemetry. These Registry capabilities remain partial/planned as applicable.

## Required reporting

- Execute `swift build` and the relevant unit/integration tests for the task.
- Execute `pearfy guardian verify` before declaring completion.
- List gates that were not run as INCOMPLETE; missing PostgreSQL/Redis or client toolchains are not passes.
- Do not weaken a gate or infer production readiness from a successful build.
- Preserve integration environment redaction; only test host presence/status is reported, never credentials.

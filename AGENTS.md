# Pearfy engineering instructions

Pearfy is a modular SwiftPM framework. Source code and tests in this checkout are authoritative; roadmap-only capabilities are not importable APIs.

## Global rules

- Preserve strict Swift concurrency, typed boundaries, bounded resources and existing user changes.
- Keep authorization server-side. Never expose credentials, request bodies, cookies, SQL bindings, personal data or tokens to Skills, MCP, logs or model context.
- Do not claim a planned or partial capability is operational. Report exact version/status from Registry and actual evidence.
- Run relevant builds/tests and `pearfy guardian verify`. Guardian is independent: unexecuted gates are INCOMPLETE, never PASS.
- PearfyAI application runtime is separate from development agents and OpenCode configuration.

<!-- pearfy-ai-context:start -->
## Pearfy Skills-first

Pearfy module details are loaded progressively. Start with `pearfy ai inspect`, identify installed modules, and read only their `.agents/skills/<skill>/SKILL.md`; open a referenced file only when that contract is needed. The Module Registry is authoritative. Planned modules have no usable API.

Prefer Pearfy CLI operations over MCP. MCP is opt-in per installed module with `pearfy ai mcp enable <module>` and is only for live/dynamic operations. Never use MCP to retrieve static module documentation. Preserve user-owned Skills and configuration during `pearfy ai sync`.

Before finishing, run the relevant build/tests and `pearfy guardian verify`. Report unavailable gates as INCOMPLETE, never PASS. Keep PearfyAI application runtime separate from development agents. Never expose credentials, request bodies, SQL bindings or private customer data to Skills, MCP, logs or model context.
<!-- pearfy-ai-context:end -->

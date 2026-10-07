---
description: Implements Pearfy GameServer features with bounded simulation, authoritative rules and module-specific adapters.
mode: subagent
---

Start with `pearfy ai inspect` and verify which GameServer products are installed and which are only planned. Read `.agents/skills/pearfy-gameserver/SKILL.md` first, then load only the adapter Skills needed for the task, such as transport, realtime, Redis recovery, PostgreSQL world state, matchmaking, Agones or DevKit. Read `docs/GAMESERVER.md` and inspect the current product source and tests before changing code. Roadmap descriptions are not APIs.

Keep gameplay authoritative on the server. Preserve strict Swift concurrency, bounded queues and byte budgets, fixed-step simulation without catch-up bursts, and server-side ticket authorization. Never put credentials, tickets, payloads, SQL bindings, personal data or transport state in logs, DevKit projections or client-visible state. Keep persistence and telemetry asynchronous and outside gameplay ticks.

Treat templates and module contracts as starter boundaries, not evidence of production capacity or a complete genre implementation. For networking or deployment work, verify the exact listener, authentication, allocation and recovery paths in source; distinguish local tests from deployed guarantees. Use Pearfy CLI operations before MCP, and only use MCP for an enabled module's live operation.

Run the focused GameServer build/tests and `pearfy guardian verify`. Report each gate as PASS or INCOMPLETE from its actual output, including any required service environment that was unavailable.

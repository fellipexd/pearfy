---
name: pearfy-gameserver-turn-based
description: Use the optional append-before-publish turn-based and point-and-click game session contract.
metadata:
  pearfy-module: gameserver-turn-based
  pearfy-skill-version: 1.0.0
---

# Pearfy GameServer turn-based sessions

- Import `PearfyGameServerTurnBased` for `GameTurnBasedSession`; the core `GameCommandProcessor` remains the in-memory option.
- Implement `GameTurnBasedCommandStore` with atomic revision compare-and-append and idempotency bound to command ID, player ID and exact payload bytes. If a prior append committed but its response was lost, return the exact event when the session has not advanced; otherwise return a revision conflict so the stale actor reopens.
- Keep reducers deterministic and validate identity, permissions, turn ownership, game rules and all command fields before producing the next state.
- `submit` calls the reducer and store asynchronously and publishes the new state only after append succeeds. Invoke it from command handling, never from a latency-sensitive simulation tick.
- On a revision conflict from another writer, stop using that actor and reopen from the latest checkpoint; do not guess which state won.
- Checkpoints retain the full bounded event history and replay every event to verify its state. This suits finite sessions; it is not an unbounded event store.
- `syncPage()` returns the current state with a revision cursor; `syncPage(afterRevision:maximumEvents:maximumBytes:)` returns a contiguous bounded event suffix. Reject future cursors and handle `hasMore` before advancing the caller cursor. State and command payloads are server-side data: authorize and project them per recipient before network serialization.
- For shared PostgreSQL sessions, add `gameserver-turn-based-postgres` and apply its migration before serving commands. For bounded Redis sessions, add `gameserver-turn-based-redis`, acquire and renew a recovery lease, and checkpoint on async maintenance. The generic state-projection adapter does not implement this command contract automatically.
- Read `pearfy-gameserver-turn-based-postgres` for the PostgreSQL adapter's transaction, limits and real-service integration gate.
- Read `pearfy-gameserver-turn-based-redis` for fencing, recovery, checkpoint and real-service integration requirements.
- Use a stable command ID for retries. Never repeat non-idempotent external effects during reducer replay; emit an outbox intent and process it separately if needed.
- Unit tests use an in-memory store and do not need infrastructure.

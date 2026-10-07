---
name: pearfy-gameserver-turn-based-postgres
description: Use the PostgreSQL transaction store for bounded Pearfy turn-based game sessions.
metadata:
  pearfy-module: gameserver-turn-based-postgres
  pearfy-skill-version: 1.0.0
---

# Pearfy GameServer turn-based PostgreSQL store

- Add both `gameserver-turn-based` and `gameserver-turn-based-postgres`; the adapter uses PearfyData `SQLDatabase` and does not replace app-owned game rules.
- Apply `PostgresGameTurnBasedCommandStore.migration(tablePrefix:)` with the application's migration catalog before serving sessions.
- All command/event/session mutations happen in one PostgreSQL transaction. A transaction-scoped advisory lock serializes stores on the same session ID across replicas; command ID uniqueness and exact player/payload comparison make retries idempotent. If another command advanced beyond an ambiguous commit, the stale actor receives a revision conflict and must reopen.
- Configure matching event, state, command and history limits on the session and adapter. Both keep the finite event history in memory/storage; there is no compaction API.
- For an unknown transaction outcome, retry the exact command ID, player ID and payload. Do not invent a new ID or emit external side effects in the reducer.
- Store state may include private game data. Keep its tables and connection credentials server-side; never publish database rows through DevKit without a separately allowlisted projection.
- Unit SQL stubs verify query composition only. Run `PostgresGameTurnBasedTests` with `PEARFY_TEST_POSTGRES_*` to verify transaction, recovery and competing writers against a real PostgreSQL service.

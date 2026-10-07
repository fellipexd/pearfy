---
name: pearfy-gameserver-postgres
description: Use for optional asynchronous PostgreSQL persistence of projected Pearfy game server state.
metadata:
  pearfy-module: gameserver-postgres
  pearfy-skill-version: 1.0.0
---

# PearfyGameServerPostgres

- Add `PearfyGameServerPostgres` only when a game server needs PostgreSQL state persistence.
- Start `PearfyPostgresDatabase` before starting `GameServerStateManager` with `PostgresGameServerStateMiddleware`.
- Apply `PostgresGameServerStateMiddleware.migration()` through the app's versioned `SQLMigrationCatalog`/`SQLMigrationRunner` before startup. The adapter uses bound parameters plus a validated table identifier. Give the migration role schema privileges and the runtime role only the required INSERT/UPDATE privileges.
- It keeps the latest revision by namespace/key; it is not an event log or a durable-commit acknowledgment.
- Writes run on the manager's bounded middleware worker. Queue overflow may replace pending state; monitor manager metrics and tune queue bounds for the recovery objective.
- Stop the manager before stopping PostgreSQL so middleware flush completes.
- Publish only allowlisted projections. Never include tickets, credentials, requests, cookies, personal data, SQL bindings or sockets.

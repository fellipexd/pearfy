---
name: pearfy-gameserver-matchmaking-postgres
description: Use for bounded cross-replica Pearfy game matchmaking queues backed by PostgreSQL.
metadata:
  pearfy-module: gameserver-matchmaking-postgres
  pearfy-skill-version: 1.1.0
---

# PearfyGameServerMatchmakingPostgres

- Import this product only when matchmaking tickets must be shared across game-server replicas.
- Start the application's PostgreSQL service and apply `PostgresGameMatchmakingQueue.migration(tablePrefix:)` through its migration catalog before startup.
- Use the same queue ID, table prefix, matchmaking policy and bounds on every replica. Treat queue ID as a server-defined pool (for example, playlist plus region); do not mix independent populations into one bounded candidate scan. Queue mutations are serialized per queue ID with a PostgreSQL transaction-scoped advisory lock; this is a control-plane design, not a high-frequency simulation path.
- Apply the v2 schema migration: it persists a per-queue scan cursor and supporting ticket index. `claimMatches` rotates the bounded candidate window, then orders that window by enqueue time before planning. This prevents the same unmatched head page from hiding later candidates indefinitely; it is not a latency/fairness guarantee under load.
- Enqueue tickets only after the application authenticates players and validates server-owned mode, region and skill data. The adapter enforces player/party uniqueness while queued and global entry/player limits for that queue ID.
- `claimMatches` atomically creates assignments and may redeliver a pending assignment with the same ID until `acknowledge` succeeds. `reconcilePendingAssignments(maximumAssignments:ensureAssignment:)` delivers a bounded batch to an async application callback outside the database transaction, then acknowledges successful results. A thrown or ambiguous callback leaves the assignment pending for retry. Make downstream room/allocation calls idempotent by assignment ID; the helper serializes duplicate delivery within one queue actor but replicas can still invoke the callback concurrently.
- `expireQueued` removes only unassigned tickets. Do not expire an assignment as if no server could have received it.
- Schedule bounded `pruneHistory(before:maximumRowsPerTable:)` calls for terminal rows; the module never deletes history automatically.
- This product does not guarantee end-to-end fairness, distributed leases for running game sessions, concrete server allocation or transactional integration with an external allocator.

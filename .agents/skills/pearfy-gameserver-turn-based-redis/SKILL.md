---
name: pearfy-gameserver-turn-based-redis
description: Use the fenced Redis Streams adapter for bounded Pearfy turn-based game sessions.
metadata:
  pearfy-module: gameserver-turn-based-redis
  pearfy-skill-version: 1.0.0
---

# Pearfy turn-based Redis store

- Add `gameserver-turn-based-redis` for `PearfyGameServerTurnBasedRedis`; it depends on `gameserver-turn-based` and `gameserver-redis-recovery`.
- Start `RedisGameStateRecoveryStore`, acquire an exclusive session lease, and only then call `RedisGameTurnBasedCommandStore.open`. The lease epoch fences all adapter writes.
- Renew the lease through `RedisGameStateRecoveryStore` before it expires for the entire lifetime of the command store. Stop accepting commands before lease loss; reopen after acquiring a new lease.
- Use the adapter with `GameTurnBasedSession` and a deterministic reducer. Append errors do not publish the candidate state. Retry ambiguous writes with the same command ID, player ID and exact payload bytes.
- Call `saveCheckpoint()` from bounded async maintenance or graceful shutdown, outside simulation ticks. The adapter stores the complete finite history in its checkpoint before the Redis recovery store trims covered stream entries.
- Configure finite event, state, command, event-record, checkpoint and total-history limits consistently with `GameTurnBasedSession` and `RedisGameStateRecoveryConfiguration`. Checkpointed history remains in Redis, so the event cap is a session lifetime cap until an application-level archival policy exists.
- Release the lease and stop the recovery store during orderly shutdown. The adapter does not own Redis lifecycle or lease renewal.
- Redis durability and recovery point depend on persistence, replication and failover configuration. Compilation or fake-store tests do not prove behavior against a real Redis service; use the gated `PEARFY_TEST_GAME_REDIS_HOST` integration test for that evidence.
- Do not use this finite-session adapter for high-frequency FPS/MMO simulation events or as an unbounded journal.

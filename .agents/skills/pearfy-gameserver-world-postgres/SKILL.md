---
name: pearfy-gameserver-world-postgres
description: Use for PostgreSQL-backed Pearfy MMO zone leases, fencing and bounded entity state.
metadata:
  pearfy-module: gameserver-world-postgres
  pearfy-skill-version: 1.0.0
---

# PearfyGameServerWorldPostgres

- Add this optional product only when zone authority and entity state must be shared across server replicas. Start the application's PostgreSQL service and apply `PostgresGameWorldLeaseStore.migration(tablePrefix:)` before use.
- Each zone has one time-limited owner lease. Use a fresh owner UUID per process lifetime, renew before expiry and stop accepting mutations if renewal fails. An expired takeover advances the fencing epoch; every entity mutation checks owner, epoch and expiry inside its transaction.
- Configure identical bounds on all replicas. Active zones, entities per zone, bytes per zone and bytes per entity are hard caps. Retire only empty zones to free an active-zone slot; retired IDs retain their fencing history and cannot be reused.
- Create, update, remove and transfer entities through the store. Transfers require live leases for both zones, lock zone IDs in a deterministic order, enforce destination limits and increment the entity epoch. Consumers should invalidate source-zone interest/state after successful transfer.
- The adapter returns PearfyGameServer's `GameWorldEntity`, so local and PostgreSQL world paths share the entity value contract.
- `entities(in:offset:limit:)` is a bounded page and must run outside the high-frequency tick. PostgreSQL is a control/persistence plane, not a per-frame simulation dependency.
- The store does not implement simulation, interest management, snapshots/deltas, distributed transactions with Redis, automatic lease renewal, client migration or multi-region recovery. Database availability and failover determine the zone control plane's availability.

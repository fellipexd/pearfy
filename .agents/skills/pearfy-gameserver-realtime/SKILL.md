---
name: pearfy-gameserver-realtime
description: Use for bounded spatial interest queries and paginated authoritative entity snapshots in Pearfy GameServer.
metadata:
  pearfy-module: gameserver-realtime
  pearfy-skill-version: 1.1.0
---

# PearfyGameServerRealtime

- Add the optional `PearfyGameServerRealtime` product when a game needs spatially bounded entity visibility. It depends on `PearfyGameServer` and does not add a listener or persistence adapter.
- Construct `GameRealtimeInterestManager` with explicit `GameRealtimeInterestConfiguration` limits. Coordinates are app-defined integer world units; `cellSize` uses the same unit and AOI radius is a square range of cells.
- Upsert only authoritative state projections. Entity revisions must increase. Entity count, individual state bytes, aggregate state bytes, candidate scans, page items, page bytes and radius all have hard bounds.
- Call `snapshot(around:radiusCells:offset:limit:expectedWorldRevision:)` outside the simulation tick for a full AOI page. The result is sorted by UUID. Pass `worldRevision` to continue a page; if the world changed, restart at offset zero to avoid gaps or duplicates.
- Call `delta(around:radiusCells:since:previousVisibleEntityIDs:offset:limit:expectedWorldRevision:)` outside the tick to reconcile a client's prior AOI. New/changed visible entities arrive as `upsert`; prior IDs no longer visible arrive as `remove`. Apply all pages, then retain the returned `worldRevision` and resulting visible ID set for the next delta. Pass the same prior IDs/base revision on every page; if the world changes, restart the delta from its original base.
- Delta pages are current-state reconciliation, not an ordered domain event log or a wire transport protocol. The caller owns encoding, authorization, delivery, retries and client state.
- A page that cannot include its first entity under the configured byte ceiling fails with `capacityReached`; reduce the area or configure a page byte budget that fits one maximum-sized entity.
- The AOI is a single-process square-cell query primitive with bounded full pages and state-reconciliation deltas. It does not provide game-specific authorization, physics, anti-cheat, a network replication protocol, storage, zone leases or cross-replica ownership. Keep returned entity visibility policy server-side.

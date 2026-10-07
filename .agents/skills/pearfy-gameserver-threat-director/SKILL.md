---
name: pearfy-gameserver-threat-director
description: Use the optional deterministic PearfyGameServer threat scoring and NPC action recommendation module.
metadata:
  pearfy-module: gameserver-threat-director
  pearfy-skill-version: 1.0.0
---

# Pearfy GameServer Threat Director

- Add the optional `PearfyGameServerThreatDirector` product when a co-op game needs bounded deterministic threat scoring.
- Feed only server-authoritative, minimized signals. Validate client movement, evidence and objective claims before they affect scores.
- Configure integer weights, increasing thresholds, hysteresis, decay, cooldown, player/event limits and finite action IDs. The director saturates pressure and does not accept arbitrary generated actions.
- Call `evaluate(_:)` from a bounded event-driven worker outside latency-critical simulation ticks. It performs no I/O and no model call; do not call Jev or persistence from the simulation hot path.
- Reuse a signal's event ID only for identical input. Conflicting reuse fails; duplicate input returns its original decision. Event history is bounded to at most 10,000 records and rejects new events when full.
- Treat `recommendedActionID` as a proposal. Validate the live world, map it to a known NPC/action, then schedule through `GameCoopSession` or the durable Redis co-op command path as required.
- `checkpoint()` includes deterministic seed, configuration and the bounded idempotency ledger. Persist the checkpoint only in a server-owned recovery path; it is not safe for clients or public DevKit projections.
- The module does not simulate movement/animation, guarantee durable storage itself, train models or retain player memory.
- Use deterministic unit tests; no live provider, database or Redis is required.

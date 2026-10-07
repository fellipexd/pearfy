---
name: pearfy-gameserver-npc-learn
description: Use the optional Pearfy game-server NPC decision module backed by typed Jev choices.
metadata:
  pearfy-module: gameserver-npc-learn
  pearfy-skill-version: 1.0.0
---

# Pearfy GameServer NPC Learn

- Add the optional `PearfyGameServerNPCLearn` product and configure `NPCLearn` with a server-side `JevDecisionClient` or an app-owned `JevDecisionProvider`.
- The default provider is TypeSafe Jev (`https://api.typesafe.ai/v1/systemone`) with model `jev-latest`; pin a tested model in production.
- Jev selects one identifier from the finite action candidates supplied by the server. It does not generate arbitrary code, dialogue, or unrestricted game actions.
- Keep API keys server-side. Pass only a minimized NPC decision context to Jev; do not include player personal data, tickets, credentials, or transport payloads.
- Call `decide` from an event-driven async worker, never from the simulation tick. The module bounds context bytes, option count and concurrent requests. Saturation throws; provider errors and low confidence use the configured safe fallback.
- Validate the returned action against authoritative game state and schedule it through the app's GameServer tick/action path. Jev output never mutates world state directly.
- `planAction(_:dueTick:scheduledActionID:)` returns a bounded, versioned `GameCoopScheduledNPCAction`; submit it through `GameCoopSession.scheduleNPCAction` or commit `.scheduleNPCAction` with `RedisDurableGameCoopSession` when the decision must survive process restart. Decode `NPCLearnedNPCAction` in the server's action handler and switch only on known IDs.
- `NPCLearn` is a bounded decision integration. It does not train/fine-tune models or persist player memory; store any learning signals using an explicit app-owned, privacy-reviewed workflow.
- Use stub `JevDecisionProvider` implementations for tests. Unit tests do not require a live Jev key or network access.

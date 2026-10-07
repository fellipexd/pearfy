---
name: pearfy-gameserver-devkit
description: Use for the asynchronous game-state manager, persistence middleware and protected DevKit state viewer.
metadata:
  pearfy-module: gameserver-devkit
  pearfy-skill-version: 1.0.1
---

# Game server state manager and dashboard

- Construct `GameServerStateManager` or use `GameServerStateManager.shared`; call `start(middlewares:)` once before publishing, or `start(restoringFrom:middlewares:)` to hydrate from a recovery middleware during startup.
- Get a `GameServerStatePublisher` and publish only allowlisted state projections. `publish` is synchronous/nonblocking, bounded, and can report a replaced older item when saturated.
- Each middleware has a separate item- and byte-bounded mailbox and worker. `maximumPendingStateBytes` defaults to 1 MiB per ingress or middleware queue; full queues replace oldest pending records. Do not await middleware or dashboard I/O from a simulation tick. A middleware can be `GameServerStateClosureMiddleware` backed by the app's bounded SQL pool or a dedicated Redis middleware.
- `snapshot()` is a bounded current-state registry, not a durable event log. Updates replace a matching namespace/key; capacity evicts the oldest current key. Counters expose publish replacement and middleware failures without error payloads.
- Restore trusted state before `start`; count, byte and identifier limits are checked before the current snapshot is replaced, so a rejected restore leaves the existing view intact. Call `stop()` to close streams, await workers and flush middleware.
- To display states, add the optional `PearfyGameServerDevKit` product, wrap the app source with `PearfyGameServerDevKit.source(manager:merging:)`, and install `PearfyDevKitUI` with an explicit bearer token. The protected UI paginates states in batches of 100 and shows at most the first 1 KiB per payload.
- Never publish tickets, signing keys, request/response bodies, cookies, personal data, raw SQL/bindings or transport objects. Dashboard previews are not a substitute for authorization or data minimization.
- Redis and SQL retries/transactions are owned by their middleware. Buffered state is best-effort: queue overflow replaces older pending updates and is not a durable-commit guarantee.

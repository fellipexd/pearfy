# PearfyGameServer

## Durable turn-based and point-and-click commands

The optional `PearfyGameServerTurnBased` product provides `GameTurnBasedSession`, which combines an async game reducer with an application-owned `GameTurnBasedCommandStore`. The store must atomically compare the current revision, append the immutable event, and deduplicate retries by command ID, player ID and exact command bytes. The session publishes its state only after append succeeds. If the response is lost after a successful append, retry the same command and the store must return the original event. A competing writer produces a revision conflict; reopen from storage instead of continuing with stale state.

`syncPage()` returns a bounded full-state snapshot and its revision cursor. `syncPage(afterRevision:maximumEvents:maximumBytes:)` returns the next contiguous page of accepted events, with a cursor and `hasMore`. The cursor must only advance after the consumer applies the entire page. The page contains authoritative state and command payload bytes; do not send it directly to clients. Authenticate the recipient and produce a per-player allowlisted projection first. Requests with future cursors, invalid limits or a first item larger than the byte budget fail closed.

Reducers own authorization, player/turn validation, command decoding and game rules. They must be deterministic because checkpoints replay the complete bounded event history and verify every resulting state. For shared sessions, add `PearfyGameServerTurnBasedPostgres` and apply `PostgresGameTurnBasedCommandStore.migration(tablePrefix:)` through the application's migration catalog. It updates session revision/state and appends the event in one PostgreSQL transaction, serializing each session across replicas with a transaction advisory lock. The generic PostgreSQL state projection and Redis recovery adapters do not replace this command store. The module retains a finite event history, so it is intended for bounded matches, not unbounded journals. Call `submit` from async command handling, outside the simulation tick. Do not repeat non-idempotent external side effects during replay; publish them through a separately idempotent outbox workflow.

```swift
import PearfyGameServerTurnBased

let session = try await GameTurnBasedSession.open(
    sessionID: sessionID,
    initialState: initialMatchState,
    store: appOwnedTransactionalCommandStore,
    reducer: { state, playerID, command in
        try await validateAndReduce(state: state, playerID: playerID, command: command)
    }
)
let result = try await session.submit(
    commandID: clientStableCommandID,
    playerID: authenticatedPlayerID,
    command: encodedIntent,
    expectedRevision: clientRevision
)
```

The command ID must remain stable across retries. If a competing replica advances the session after an ambiguous append, the stale actor gets a revision conflict and must reopen instead of publishing the older event as current state. Checkpoint and replay are bounded by the session's configured event, command, state and history limits. For volatile single-process games, the core `GameCommandProcessor` remains available without the optional durable store boundary.

The PostgreSQL adapter has a dedicated Registry module, `gameserver-turn-based-postgres`, which requires `gameserver-turn-based` and `postgres`. SQL stub tests validate bound parameters and transaction composition; configure `PEARFY_TEST_POSTGRES_HOST` and the other `PEARFY_TEST_POSTGRES_*` variables to run the integration test for recovery and competing writers against a real service.

The optional `PearfyGameServerTurnBasedRedis` product is registered as `gameserver-turn-based-redis` and requires `gameserver-turn-based` plus `gameserver-redis-recovery`. Start `RedisGameStateRecoveryStore`, acquire the per-session fencing lease, then open `RedisGameTurnBasedCommandStore`; renew the lease for the adapter lifetime and release it during graceful shutdown. `saveCheckpoint()` is an async maintenance operation that persists the complete finite history before the covered Redis stream prefix is trimmed. Set adapter limits consistently with the session and recovery store. This is bounded finite-session storage, not an unbounded event log; Redis persistence and replication determine the recovery point. Unit tests exercise append/reopen/fencing with an in-memory recovery store, and `PEARFY_TEST_GAME_REDIS_HOST` enables the real-Redis integration test.

## Event-driven NPC decisions

The optional `PearfyGameServerNPCLearn` product connects the `PearfyAI` runtime to the GameServer application boundary. Its default provider is TypeSafe Jev through the typed `choice` decision API (`JevDecisionClient`, model `jev-latest`). The app supplies a minimized NPC state and a finite set of server-authored action candidates. Jev returns one candidate identifier and confidence; low confidence or provider failure selects the app-configured safe fallback.

These calls run in a bounded async worker outside the simulation tick. The integration limits context to 16 KiB, candidates to 32 and concurrent requests to a configured maximum; saturation rejects the new request. `planAction(_:dueTick:scheduledActionID:)` converts the decision into a bounded, versioned `GameCoopScheduledNPCAction` carrying only the selected allowlisted ID, confidence and fallback flag. Schedule it with `GameCoopSession.scheduleNPCAction`, or commit `.scheduleNPCAction` via `RedisDurableGameCoopSession` if it must survive process restart. The authoritative tick handler decodes `NPCLearnedNPCAction`, validates the current world and switches only on known action IDs. No API credential, raw player payload or unrestricted model action belongs in game state. This product does not train a model or retain player memory.

Jev is the default provider. Construct it with a server-side secret and optionally pin a model; use the provider initializer only when supplying a different PearfyAI decision provider:

```swift
import PearfyGameServerNPCLearn

let npcLearn = try NPCLearn(
    apiKey: environment["JEV_API_KEY"]!,
    model: "jev-latest",
    maximumConcurrentRequests: 8
)
let action = try await npcLearn.planAction(
    NPCDecisionContext(
        npcID: "guard-1",
        state: minimizedServerAuthoredState,
        question: "Choose the next action for this NPC.",
        candidates: [
            NPCActionCandidate(id: "patrol", description: "Continue the patrol"),
            NPCActionCandidate(id: "wait", description: "Wait at the gate")
        ],
        safeFallbackActionID: "wait"
    ),
    dueTick: nextDecisionTick
)
// Enqueue/commit `action` through the authoritative GameServer path.
```

“Learn” here means selecting an NPC action from current bounded context. It does not train or fine-tune Jev. The caller should build the state projection from server-owned facts, excluding player identity/personal data and untrusted raw messages. The module cannot validate game-specific preconditions, so revalidate the selected action immediately before scheduling/execution.

## Deterministic threat director

The optional `PearfyGameServerThreatDirector` product provides bounded integer threat scoring for co-op sessions. Applications configure signal weights, pressure thresholds, hysteresis, tick decay, action cooldowns, a seeded finite list of action IDs per level, and a capped event history of at most 10,000 signals. Call `evaluate(_:)` from a bounded event-driven worker outside latency-critical simulation ticks. It is deterministic and idempotent by event ID; reusing an ID with different signal content fails. Pressure saturates at its configured maximum, and new events are rejected when history reaches its limit. The returned action ID is only a recommendation: validate it against current authoritative world state, then map it to a known NPC action and schedule it through `GameCoopSession` or `RedisDurableGameCoopSession`. Checkpoints contain the seed, configuration and dedupe history and must remain server-only. This module does not simulate NPC movement, persist checkpoints itself or replace optional Jev decisions.

`PearfyGameServer` is an optional server-side module for applications that issue PearfyEngine `PearfyNetwork` clients with short-lived game session credentials. Install it with `pearfy add gameserver` and add the `PearfyGameServer` SwiftPM product to the server target. Its local runtime now includes bounded rooms, idempotent turn-based commands, realtime input buffering, matchmaking primitives, co-op mission state, optional threat scoring and a single-process zone registry. These stores are in-process and do not provide multi-replica consistency.

## CLI starter modes

Run `pearfy gameserver modules` to list game-server modules from the Module Registry, including their actual `partial`/`planned` status and installability. Run `pearfy gameserver modes` to compare the starter profiles. Generate JSON to stdout with `pearfy gameserver template --mode light|medium|high`, or write a new file with `--output gameserver.json`. The CLI refuses to overwrite an existing file. These are starting limits, not measured host capacity guarantees.

Use `pearfy gameserver recipe turn-based|fps|friendslop|mmo|rooms|dedicated` to print a JSON composition plan, or add `--output recipe.json` to create a new file without replacing an existing one. A recipe lists required/optional Registry module IDs, available primitives, application-owned responsibilities and production gates. It is not a game implementation or automatic module installer. `fps` and `mmo` use the `high` profile; `friendslop` starts at `medium`. The generated high-mode recipe keeps UDP disabled until application key provisioning and the full socket/abuse path are validated.

| Mode | Transport and format | Memory approach | Initial limits |
| --- | --- | --- | --- |
| `light` | TLS gRPC control + TLS WebSocket gameplay, JSON | Swift ARC defaults | 32 sessions, 2 MiB queue, 64 KiB message, 60 messages/s/player; 20Hz, 2,048 queued inputs, 128 inputs/tick, 64 inputs/64 KiB per player |
| `medium` | Same transports and JSON | Ownership-oriented values/buffers to reduce copies and ARC traffic; ARC stays active | 256 sessions, 16 MiB queue, 64 KiB message, 120 messages/s/player; 30Hz, 16,384 queued inputs, 1,024 inputs/tick, 128 inputs/128 KiB per player |
| `high` | TLS gRPC control + target UDP gameplay, binary | Ownership-oriented values/buffers; ARC stays active | 2,048 sessions, 64 MiB queue, 1,200-byte datagram, 240 messages/s/player; 60Hz, 65,536 queued inputs, 8,192 inputs/tick, 256 inputs/256 KiB per player |

Swift uses Automatic Reference Counting (ARC), not a tracing garbage collector that can be switched off per profile. “Ownership” here means designing data paths around value semantics, borrowing and fewer copies; it does not disable ARC. The `high` template records UDP/binary as the target, but keeps `udpEnabled` set to `false` until deployment checks are complete. The optional server transport and PearfyNetwork client provide matching ChaCha20-Poly1305 datagrams, direction-separated HKDF keys, a 64-packet replay window, and bounded transports; the server adds session, datagram, rate and buffer limits. `GameServerUDPAdmissionManager` authenticates the ticket, creates a fresh random 256-bit key and registers the validated principal. The isolated interoperability harness performs an authenticated TLS gRPC join, returns the admitted channel credentials, and completes a real PearfyNetwork-client-to-Pearfy-server UDP socket roundtrip. Its burst case verifies independent per-player work limits. Deployed Agones, broader abuse checks and benchmarks on target hardware remain before enabling the profile. No profile claims a benchmarked capacity.

Each template also includes fixed-step work limits and a circuit breaker set to three consecutive overruns. Configure `GameRealtimeSimulation` with its `maximumQueuedInputs`, `maximumQueuedInputsPerPlayer`, `maximumQueuedBytesPerPlayer`, `maximumQueuedBytes` from `resourceLimits.maximumQueuedBytes`, `maximumInputBytes` from `resourceLimits.maximumMessageBytes`, and `maximumPlayers` from `resourceLimits.maximumSessions`; then use `GameRealtimeFixedStepDriver` with `tickRateHz` and `maximumInputsPerTick`. The defaults are starting admission budgets, not a promise that the machine sustains the maximum session count at that rate. If a handler reaches the next scheduled deadline for three ticks in a row, the driver stops, marks itself overloaded/failed, and closes simulation input admission while preserving queued inputs for recovery. A reducer or tick-advance error also closes admission. Recover or drain the queue, call `resumeInputAdmission()` only when it is empty, then create a new driver. Watch `overrunCount` and queue metrics to shed load before the circuit breaker trips. These limits bound queued input and fail closed on sustained slow ticks; they cannot bound CPU time inside application rules or guarantee a deployment never overloads. Benchmark the target hardware and size the workload before advertising capacity.

## Session ticket authority

Create a `GameServerConfiguration` with the protocol version, a ticket lifetime up to one hour, and a maximum number of active tickets. Construct `GameSessionTicketAuthority` with a server-side signing key of at least 32 bytes. Do not store the key in source, mobile builds, Skills, or logs.

After the application authenticates a player and allocates a room, issue a ticket for the exact `sessionID` and `playerID`. Return the ticket, `sessionID`, gateway URL and negotiated version to the client. `GameSessionOffer` accepts only `wss://` endpoints without credentials, query strings or fragments. Send the ticket as the WebSocket Bearer credential, never as a URL parameter. Call `authenticate` at the gateway boundary for every session admission and `revoke` on leave or disconnect policy.

```swift
let config = try GameServerConfiguration(supportedProtocolVersion: 1, ticketLifetime: 120)
let tickets = try GameSessionTicketAuthority(configuration: config, signingKey: serverSecret)
let ticket = try await tickets.issue(sessionID: sessionID, playerID: playerID)
let principal = await tickets.authenticate(
    ticket,
    sessionID: sessionID,
    playerID: playerID,
    protocolVersion: 1
)
```

Ticket descriptions are redacted, but the explicit `value` and `bearerAuthorizationValue` properties contain credentials. Never log or persist them as ordinary diagnostics. Matchmaking and room ownership remain application policy; implement `GameMatchmaking` only after authenticating and authorizing the caller.

## Integration with the game client

The game client uses PearfyEngine's separate `PearfyNetwork` product. The service endpoint should provide TLS gRPC unary methods for matchmaking and room lifecycle, then an authenticated TLS WebSocket endpoint for real-time traffic. Negotiate the same protocol version on `join`, validate client sequence and payload limits, and keep server snapshots authoritative. Keep network work outside the synchronous scene update loop.

`PearfyGameServer` itself has no listener, matchmaking service or simulation. The separate optional `PearfyGameServerGRPC` and `PearfyGameServerTransport` products provide gRPC/TLS control and WSS/TLS gameplay listeners. Ticket issuance and revocation use bounded in-process state, so a ticket is accepted only by the authority instance that issued it. A multi-instance deployment needs a shared ticket/session store and coordinated revocation before it can route connections freely.

## Optional gRPC control plane

Add the `PearfyGameServerGRPC` product for the versioned unary control services expected by PearfyEngine. Its protobuf contract declares `pearfy.matchmaking.v1.Matchmaking/FindGame`, `pearfy.matchmaking.v1.Matchmaking/CreateRoom`, `pearfy.game.v1.GameSession/Join`, and `pearfy.game.v1.GameSession/Leave`. Requests and responses carry an opaque `bytes payload`; the application owns that payload schema, validates it, applies matchmaking/session policy and returns the authoritative response. This keeps application contracts versioned independently while matching PearfyNetwork's service/method paths.

`GameServerGRPCServer` requires a readable PEM certificate chain and matching private key, enforces ALPN, and requires one `authorization: Bearer …` metadata value before calling the app authorization closure. Use `GameSessionTicketAuthority.authenticate` or equivalent server-side policy there, including ticket expiry/revocation and session/player/protocol binding. The dispatch closure receives only the method, payload bytes and validated `GameSessionPrincipal`. Failures return generic statuses; credentials and payload contents are not logged. Configure maximum request/response bytes, accepted connections, concurrent streams per connection and the aggregate in-flight payload budget; the configured maxima must fit that budget. `start()` reports the bound address (port 0 is supported); `stop()` drains in-flight requests. The current gRPC Swift 2 API is available on macOS 15+/iOS 18+; use the POSIX listener on dedicated Linux servers.

The protobuf wrapper is binary, but it does not define a JSON schema or gameplay protocol. For compatibility with PearfyEngine `PearfyNetwork`, clients must use the same unary gRPC service/method names, protobuf envelope and bearer metadata. The server-side transport integration test verifies the generated Swift client against this listener; the app must still test its own payload schema and ticket policy end to end.

## Optional WSS transport

Add `PearfyGameServerTransport` to install its SwiftNIO listener. Configure a certificate chain/private key, route path, connection/message/rate limits, aggregate buffered-payload budget, bounded inbound frames, idle read timeout, an async bearer-ticket authorization closure returning `GameSessionPrincipal`, and an async authoritative message callback. The callback receives text or binary message bytes and may return one response payload; the app owns payload decoding, command validation, session/player/protocol binding, and game rules. The listener requires TLS 1.2+, caps aggregate inbound buffering, applies watermarked backpressure, rejects URL query strings, and closes idle/active connections. Reconnect is a fresh authenticated admission.

The transport module also exposes `GameServerSecureDatagramCodec`, `GameServerUDPServer` and `GameServerUDPAdmissionManager`. The admission manager authenticates a `GameSessionTicket`, generates a fresh random 256-bit key and distinct channel UUID, then registers a server codec for the validated principal. The channel UUID is separate from the shared game session UUID, so each player has an independent key and replay window. Return the key only through the authenticated confidential control response and call `revoke(channelID:)` on ticket expiry, revocation or leave. PearfyEngine `PearfyNetwork.SecureUDPTransport` uses the returned channel UUID and key. Set both codec payload limits to `GameServerUDPConfiguration.maximumPayloadBytes`; only the server-role codec can be registered on the server. The binary header binds protocol version, direction, channel UUID and sequence as AEAD associated data. Replays, stale packets, invalid tags, wrong channels and oversized datagrams are rejected. The UDP server processes one admitted command at a time and has hard session, datagram, buffer and global/per-session rolling one-second rate limits; the rolling window prevents a fixed-window boundary from admitting a double burst. It drops malformed or over-limit input without logging contents. Since v1 has no address-validation handshake, replies are capped at the size of their triggering datagram to prevent UDP amplification. `Integration/GameServerUDPInterop/run.sh` validates a TLS gRPC join, ticket authorization, channel-key delivery, the PearfyNetwork UDP client to the live server socket, revocation, and per-player burst limits. Deployed Agones and target-hardware abuse/performance validation remain pending, so high-profile UDP remains disabled.

```swift
let udpConfiguration = try GameServerUDPConfiguration(
    host: "0.0.0.0",
    port: 9000,
    maximumDatagramBytes: 1_200
)
let datagramServer = GameServerUDPServer(configuration: udpConfiguration) { principal, command in
    try await authoritativeGame.handle(principal: principal, command: command)
}
let udpAdmission = try GameServerUDPAdmissionManager(
    ticketAuthority: ticketAuthority,
    server: datagramServer,
    maximumPayloadBytes: udpConfiguration.maximumPayloadBytes
)
try await datagramServer.start()
let credentials = try await udpAdmission.admit(
    ticket: ticket,
    sessionID: sessionID,
    playerID: playerID,
    protocolVersion: 1
)
let controlResponse = JoinUDPResponse(
    channelID: credentials.channelID,
    sessionSecret: credentials.sessionSecret.withUnsafeBytes { Data($0) }
)
// Send controlResponse only through the authenticated TLS control plane.
```

Call `udpAdmission.revoke(channelID:)` when the session expires or the ticket is revoked, and call `stop()` during shutdown. The current server only replies to authenticated input and never sends a larger datagram than it received; server-initiated snapshot fanout still needs an address-validation/push design.

## Optional Agones SDK lifecycle

Add `PearfyGameServerAgones` to let a dedicated process use the Agones SDK sidecar REST API. The adapter reads `AGONES_SDK_HTTP_PORT`, restricts the endpoint to loopback, uses the bounded outbound `CloudHTTPClient`, and provides health heartbeat, `ready`, opt-in SDK `allocate`, bounded `/gameserver` status, and `shutdown` lifecycle calls. Start its heartbeat during process initialization; call `ready()` only after the game transport and authoritative game state are initialized. App shutdown drains the heartbeat and asks the SDK sidecar to shut down.

For ordinary Fleet scheduling, use `AgonesAllocatorClient` to call the external Agones Allocator Service over mTLS. Configure the endpoint, namespace, client certificate/key, trusted server CA and server certificate name. The call has a bounded deadline and payload, validates the returned server endpoint, and is attempted once: a timeout can have an ambiguous allocation outcome, so callers must not blindly retry. A resource-exhausted response is surfaced as `AgonesAllocatorError.noServerAvailable`. Example:

```swift
let allocator = AgonesAllocatorClient(configuration: try AgonesAllocatorConfiguration(
    host: allocatorHost,
    port: 443,
    namespace: "game-prod",
    clientCertificatePath: allocatorClientCertificate,
    clientPrivateKeyPath: allocatorClientKey,
    serverCAPath: allocatorServerCA
))
let server = try await allocator.allocate(try AgonesAllocationRequest(
    matchLabels: ["agones.dev/fleet": "match-prod"],
    metadataLabels: ["match": matchID]
))
```

If the Allocator is addressed by IP, pass `serverName` matching a DNS SAN on its certificate. This product still does not use Kubernetes credentials, deploy Fleets, implement application matchmaking, or configure cross-cluster placement policies. SDK sidecar calls are asynchronous and do not establish a cluster-wide state observation. See the official [Allocator Service guide](https://agones.dev/site/docs/advanced/allocator-service/) and [allocation protobuf](https://github.com/agones-dev/agones/blob/release-1.61.0/proto/allocation/allocation.proto). The local mTLS contract is integration-tested; a real Agones cluster gate is still required before production claims.

## Runtime primitives and limits

`GameRoomManager`, `GameMatchmakingQueue`, `GameCommandProcessor`, `GameRealtimeSimulation`, `GameRealtimeFixedStepDriver`, `GameCoopSession` and `GameWorldRegistry` are bounded in-process primitives. Rooms enforce capacity, consume player-bound expiring invitations only after a successful join, enforce reconnect deadlines at `join` even when `reapExpired` has not run, and expose bounded `publicRooms(offset:limit:)` discovery entries that omit member identities. A test creates and disposes 1,000 rooms at the configured cap; this is functional bound coverage, not a throughput benchmark. The command reducer treats an identical `(commandID, playerID, payload)` as a duplicate and rejects reuse of that ID by another player or with different bytes. `GameCommandProcessor(replaying:from:reducer:)` can rehydrate a complete `checkpoint()` by replaying each event and rejecting sequence gaps, repeated IDs, over-limit records or state divergence. This is startup validation for an app-persisted full command history. For bounded discrete commands, `RedisDurableGameCommandSession` provides a separate write-ahead commit path; the in-process processor and newest-wins Redis projection middleware are not durable command transactions. Realtime input enforces global and per-player count/byte limits, rejects stale client sequences, and leaves capacity available for other players when one player's budget is exhausted. Its fixed-cardinality `metrics()` reports current tick/queue pressure plus accepted, capacity-rejected, oversized and stale input counts, without player-level metric cardinality. `GameRealtimeFixedStepDriver` calls a synchronous application reducer on a monotonic cadence with a hard per-tick input cap. The handler must not suspend or perform network/storage I/O; when processing reaches the next scheduled deadline, the driver counts an overrun and schedules the next step one full period after the slow handler returns rather than issuing catch-up bursts. Three consecutive overruns stop the driver and close input admission while retaining queued inputs; a reducer or tick-advance error also fails closed. The application must recover/drain queued inputs, call `resumeInputAdmission()` only after the queue is empty, and start a new driver. This bounds runaway queue growth and avoids catch-up bursts, but cannot guarantee that application rules fit the tick budget or that a deployment never overloads; capacity requires target-hardware benchmarks. The core does not implement physics, validate genre-specific movement or automatically connect to Redis recovery. It also provides revision validation, reconnect grace, fixed-step input drains, objective visibility and zone fencing. It does not add a network listener, game-specific rules/physics, a distributed queue by default or MMO simulation. The optional `PearfyGameServerRealtime` product adds a bounded integer-coordinate cell index, stable byte/item-paged AOI snapshots and current-state reconciliation deltas (`upsert`/`remove`) against a bounded prior visible-ID set. Delta pages carry a base and current world revision; apply every page before advancing the client cursor, and restart from the original base if a mutation invalidates pagination. These are state-reconciliation primitives, not a transport protocol, event log or cross-replica authority. The optional `PearfyGameServerWorldPostgres` product adds bounded cross-replica zone leases and entity handoff in a SQL control/persistence plane, not in the tick.

```swift
let profile = GameServerModeProfile.preset(.high)
let simulation = try profile.makeRealtimeSimulation()
let driver = try profile.makeRealtimeFixedStepDriver(simulation: simulation) { tick in
    // Decode, validate and apply the app's authoritative rules synchronously.
    // Do not perform Redis, database or transport I/O in this closure.
}
await driver.start()
// On shutdown, stop the driver and inspect metrics for overruns before closing the session.
await driver.stop()
```

`GameCoopSession` is an early objective-state primitive. Its command-ID history is bounded, replay identity is bound to player/objective/progress delta and public/private state digests, and the aggregate public/private session state is byte-capped. Reusing an ID with different input raises `commandIDConflict`; reaching the configured history ceiling raises `historyCapacityReached` before mutation. Its optional `objectivePrerequisites` graph is validated at construction (known objectives, no cycles, at most 16,384 dependency edges), and dependent objectives cannot complete before every prerequisite. Optional per-objective progress targets are positive and bounded by the declared objective set; progress only increases, caps at the target and completes the objective atomically. An optional `deterministicSeed` enables a reproducible SplitMix64 sequence for application-owned authoritative decisions; member snapshots expose only the draw count, never the seed. The bounded NPC scheduler accepts trusted server-authored opaque actions, orders them by due tick and action ID, limits queued items/bytes/history and drains only a configured number per call. The game loop must poll it; applications still define NPC behavior and must not map untrusted client requests directly to `scheduleNPCAction`. Session end discards queued work. `recoveryCheckpoint()` captures a size-capped server-only JSON checkpoint paired with its session revision and performs encoding off the session actor; `GameCoopSession(restoringCheckpoint:)` validates limits and internal consistency before restoring objective progress, command dedupe history, private state, seed/draw cursor and scheduled NPC actions. The session revision counts co-op mutations and is distinct from the Redis event-journal revision. Persist the data in `GameStateCheckpoint(revision: latestJournalSequenceCovered, state: captured.data, events: [])` under an active Redis lease; a checkpoint before any journal events uses revision `0`. Restore before admitting gameplay. The checkpoint contains private state and seed material; never expose it to clients or DevKit. `PearfyGameServerThreatDirector` supplies optional bounded pressure scoring, but game-specific signals, NPC simulation and process placement remain application responsibilities; reconnect and abandonment use the session policy below.

Co-op membership supports `disconnect(playerID:gracePeriodMilliseconds:now:)`, authenticated `reconnect(playerID:now:)`, explicit `abandon(playerID:)` and bounded `expireDisconnectedMembers(now:)`. A disconnect keeps its original deadline on duplicate notifications; while disconnected, the member cannot read a session snapshot or submit objective commands. Reconnect must happen before the deadline; expiry removes the member's private state, retains the occupied seat for that session and fails the session once nobody remains connected or eligible to reconnect. Call the expiry method from app maintenance to clean expired seats; authorization does not depend on that maintenance call. Recovery checkpoints persist disconnect deadlines and abandonment state, while older checkpoint envelopes without these optional fields still restore as connected members.

```swift
import PearfyGameServerRealtime

let interest = GameRealtimeInterestManager(configuration: try GameRealtimeInterestConfiguration(
    cellSize: 100,
    maximumRadiusCells: 8,
    maximumEntities: 20_000,
    maximumEntityStateBytes: 2_048,
    maximumTotalStateBytes: 32 * 1_024 * 1_024,
    maximumQueryCandidates: 2_000,
    maximumPageEntities: 128,
    maximumPageBytes: 128 * 1_024
))
let page = try await interest.snapshot(around: .init(x: 1_250, y: -300), radiusCells: 8)
```

Coordinates and cell size share app-defined integer units. Continue with `page.nextOffset` and `expectedWorldRevision: page.worldRevision`; if that throws `worldChanged`, restart at offset zero. Keep the query off the simulation tick and enforce per-player visibility authorization before sending any entity state.

For incremental AOI reconciliation, retain the client's last visible IDs and completed world revision. Use the same base revision and ID set for every page, then advance them only after all pages are applied:

```swift
let baseRevision = clientWorldRevision
let previousVisibleIDs = clientVisibleEntityIDs
var reconciledVisibleIDs = previousVisibleIDs
var offset = 0
var expectedRevision: UInt64?
var completedRevision = baseRevision
while true {
    let delta = try await interest.delta(
        around: playerPosition,
        radiusCells: 8,
        since: baseRevision,
        previousVisibleEntityIDs: previousVisibleIDs,
        offset: offset,
        limit: 128,
        expectedWorldRevision: expectedRevision
    )
    for change in delta.changes {
        switch change {
        case .upsert(let entity): reconciledVisibleIDs.insert(entity.id)
        case .remove(let entityID): reconciledVisibleIDs.remove(entityID)
        }
    }
    completedRevision = delta.worldRevision
    guard let nextOffset = delta.nextOffset else { break }
    offset = nextOffset
    expectedRevision = delta.worldRevision
}
clientVisibleEntityIDs = reconciledVisibleIDs
clientWorldRevision = completedRevision
```

These deltas reconcile current visible state; they are not an ordered domain event log or a wire protocol. If any page throws `worldChanged`, restart from the original base revision and visible-ID set. The application owns encoding, authorization, delivery, retries and client state.

## Asynchronous state manager and WebUI

For optional snapshots, add `PearfyGameServerDevKit` and compose the source with the app's existing DevKit source. For concrete PostgreSQL persistence, add `PearfyGameServerPostgres` and pass `PostgresGameServerStateMiddleware` alongside the Redis middleware. The database service must be started before the state manager.

```swift
let states = GameServerStateManager.shared
let postgres = try PostgresGameServerStateMiddleware(database: database)

// Start Redis and PostgreSQL, and apply the PostgreSQL migration before this block.
try await recoveryStore.start()
let lease = try await recoveryStore.acquireLease(sessionID: sessionID)
let redis = try RedisGameServerStateMiddleware(store: recoveryStore, sessionID: sessionID, epoch: lease.epoch)
try await states.start(restoringFrom: redis, middlewares: [postgres])
let publisher = try await states.publisher()
try await PearfyGameServerDevKit.install(
    on: router,
    configuration: devKitConfiguration,
    manager: states,
    merging: appDashboardSource
)

// In a game tick, encode only the allowlisted projection and enqueue it without await/I/O.
let state = try GameServerStateRecord(namespace: "match", key: matchID, revision: revision, payload: stateProjection)
_ = publisher.publish(state)

// On graceful shutdown: drain persistence before closing its backing services.
await states.stop()
_ = try await recoveryStore.releaseLease(lease)
try await recoveryStore.stop()
try await database.stop()
```

Publish allowlisted state projections through `publisher.publish(record)`; it is synchronous/nonblocking and performs no Redis or SQL I/O. Ingress and each middleware worker have separate newest-wins mailboxes bounded by both item count and `maximumPendingStateBytes` (1 MiB per queue by default). Oversized backlogs replace older pending projections and update the drop metric, keeping slow persistence from growing memory without limit. Every middleware has its own async worker, so a slow persistence sink does not stall state capture or the game tick. Concurrent shutdown callers share the same drain; shutdown requested during startup restore waits until startup has completed before flushing. This is best-effort async persistence, not durable-commit acknowledgment. Redis session leases use a new owner UUID per process, monotonically increasing fencing epochs, bounded expiry and explicit renewal. Redis append/checkpoint scripts reject missing/expired leases and old epochs; renew failure must stop durable mutations. The journal has an exact event cap and rejects appends with `journalCapacityReached` rather than trimming events still needed after the last checkpoint; a durable game action must remain pending or be rejected until the application checkpoints and the append succeeds. Call `stop()` during shutdown to drain streams and flush middleware, release the session lease, then stop PostgreSQL and Redis. Restore Redis state before `start()` using `restore(_:)`.

The bearer-protected DevKit page contains “Estados do game server” and reads `/__pearfy/devkit/api/game-states` in pages of up to 100 when requested; it does not push updates in real time. Page lookup reads only the requested slice from the retained-state index. It displays at most the first 1 KiB of each payload; provide a strict allowlisted projection because authorized dashboard operators can inspect it. The PostgreSQL adapter exposes a versioned additive migration and uses bound values plus a validated table identifier; it only replaces a row with a newer revision. The Redis state-projection adapter rejects stale revisions before appending and rejects payload changes that reuse a revision; this protects projection ordering only and is not a durable game-command transaction. Apply `PostgresGameServerStateMiddleware.migration()` through the app's migration catalog before startup. To add Redis journaling, add the separate `PearfyGameServerRedisRecovery` product, start `RedisGameStateRecoveryStore`, acquire/renew a session lease before `start(restoringFrom:middlewares:)`, and release it after the state manager drains. For co-op state, call `let captured = try await gameSession.recoveryCheckpoint()` outside the realtime tick and save `GameStateCheckpoint(revision: latestJournalSequenceCovered, state: captured.data, events: [])` under the active lease. Redis revision is an event-journal sequence, distinct from `captured.sessionRevision`. Restore before admitting gameplay. Checkpoints above 256 KiB use SHA-256 checked 256 KiB Redis string chunks; a fenced Lua script atomically publishes the manifest and watermark after verifying the complete candidate, then removes chunks from the prior generation. Restore keeps compatibility with the legacy base64 value and fails closed when any chunk is missing, oversized or corrupt. The checkpoint JSON and base64 staging are still materialized in memory before splitting, bounded by `maximumRecordBytes`. Non-loopback Redis connections require `tlsEnabled: true` with full certificate verification and the certificate's server name; plain Redis is restricted to loopback. Redis AOF/RDB/replication configuration determines the real crash/failover RPO; the manager does not wait for Redis writes.

The manager exposes `GameServerStateManager.shared` for process-wide composition, but can be instantiated with its own retained-state and pending-update limits for tests or isolated game processes. Do not start the singleton twice.

`RedisGameServerStateMiddleware` checkpoints after `checkpointEvery` persisted projections or, when configured, on the first state update after `checkpointIntervalMilliseconds`; while idle it does not write repeated identical watermarks. `flush()` saves the latest middleware projection on graceful shutdown. For other application-owned state, `GameStateRecoveryCheckpointScheduler` can periodically invoke an async capture closure and save its bounded checkpoint outside the game tick. That closure must pair state with the exact latest journal sequence it includes, and those events must already be durable before the checkpoint covers them. The scheduler rejects overlapping captures and oversized snapshots; metrics expose counts and the last successful timestamp without retaining errors or payloads. It does not append events, manage leases, restore application state, or save a final checkpoint automatically on `stop()`; call `checkpointNow()` before shutdown when needed.

### Redis recovery starter configuration

In a Pearfy-managed project that already resolves both `gameserver` and `redis`, run `pearfy gameserver recovery --store redis` to inspect the proposed module selection and secret-free configuration. It is a dry run. Add `--apply` to select `gameserver-redis-recovery` and write `.pearfy/gameserver-recovery.json`; `--output <file>` changes the destination. Existing output files are never overwritten. Schema 3 names environment variables for connection data but contains no credentials. Its limits map to the Redis adapter defaults, include checkpoint cadence guidance (100 events or 30 seconds), and include separate tick-writer state, batch and queue bounds; pass `checkpointIntervalMilliseconds` from the configuration to `RedisGameServerStateMiddleware` when composing the manager. Its persistence section distinguishes best-effort asynchronous projections from write-ahead command and tick-batch commits, documents lease-loss handling, and states that no recovery point objective is guaranteed. The recommended Redis AOF settings are operational guidance; Redis replication/failover, queue saturation, crashes and deployment tests still determine real recovery behavior.

### Durable command commit with Redis

For discrete authoritative commands, use `RedisDurableGameCommandSession` instead of treating `GameServerStateManager` projections as a command log. Acquire the session lease first, then call `open(...)`; a new session writes its initial checkpoint, and a recovered session replays the journal suffix through the same deterministic reducer.

```swift
let commands = try await RedisDurableGameCommandSession.open(
    sessionID: sessionID,
    lease: lease,
    store: recoveryStore,
    initialState: initialState,
    reducer: { state, playerID, command in
        try gameReducer(state: state, playerID: playerID, command: command)
    }
)

let receipt = try await commands.commit(
    commandID: commandID,
    playerID: playerID,
    command: encodedCommand,
    expectedRevision: clientRevision
)
// Return success only after commit returns; apply per-player visibility before sending state.
try await commands.checkpoint() // call at the configured maintenance cadence
```

`commit` calculates the candidate state, appends the command and a SHA-256 digest of its result, then updates the actor's committed state. If append fails, the in-memory revision stays unchanged. Retry an ambiguous outcome with the same command ID and identical player/command; reuse with a different command fails. A bounded idempotency window is included in checkpoints. One unresolved commit blocks another command or checkpoint for that session, keeping its sequence ordered. These async calls may wait on Redis, so call them from command/control tasks and never from a simulation tick. This API is for bounded discrete commands; do not journal every FPS/MMO movement tick through it. The application still owns authentication, deterministic reducer rules, player-specific output filtering, lease renewal, and pausing/rejecting admission when commit cannot complete. Redis durability remains bounded by its configured persistence and failover policy.

For the co-op primitive, `RedisDurableGameCoopSession` supplies an async reducer that restores a bounded `GameCoopSession`, applies one typed lifecycle, objective, server-authored NPC scheduling or seeded random-decision transition, and returns its private recovery checkpoint. Open a new session with `open(initialSession:lease:store:configuration:)`; after takeover, use `open(sessionID:lease:store:configuration:)`. Both require the session's current fencing lease. `commit(commandID:playerID:command:expectedRevision:)` supports join/start, disconnect/reconnect/abandon, objective completion/progress, server-authored NPC action scheduling, expiry, finish and close. `deterministicDecision(commandID:playerID:expectedRevision:)` additionally appends a seeded decision before deriving its SplitMix64 value from the committed journal sequence. The player must be a current active member; retrying the same command ID returns the same sequence and value, including after later commands or checkpoint recovery. The outer command ID is also the co-op objective dedupe ID, so replay bytes and idempotency remain stable. Read through `snapshot(for:)`, which applies the domain's per-player authorization/visibility checks. The async reducer holds the commit gate while actor work is suspended, appends before advancing state, and blocks concurrent commands/checkpoints. Keep this call outside the simulation tick. The direct `GameCoopSession.nextDeterministicValue()` API remains in-memory only; frame input and NPC schedule drains also remain outside this durable command adapter.

```swift
let mission = try await RedisDurableGameCoopSession.open(
    initialSession: gameCoopSession,
    lease: lease,
    store: recoveryStore,
    configuration: durableCommandConfiguration // allow enough bytes for the full recovery checkpoint
)
let receipt = try await mission.commit(
    commandID: commandID,
    playerID: playerID,
    command: .completeObjective(
        objectiveID: "restore-power",
        playerID: playerID,
        publicState: publicMissionState,
        privatePlayerState: privateEvidence
    )
)
let playerSnapshot = try await mission.snapshot(for: playerID)
```

The Redis command state is the full bounded co-op checkpoint, including private state and seed material; it must never be sent directly to a client. Only the filtered `GameCoopSnapshot` is suitable for that player, with any additional application-specific field filtering applied before transport. The domain checkpoint encoder sorts set-backed collections so reducer replay yields identical bytes across process launches.

### Durable simulation tick batches with Redis

`RedisDurableGameTickSession` is the write-ahead path for continuous authoritative state. It stores a bounded batch of consecutive tick records in one Redis append, then applies the same async application reducer during live commit and recovery. Each tick can carry server-authored movement/NPC/timer/inventory transitions and the exact RNG draws consumed by the reducer. The app defines and validates each transition schema; these payloads must include every confirmed mutation needed to reconstruct the state.

```swift
let ticks = try await RedisDurableGameTickSession.open(
    sessionID: sessionID,
    lease: lease,
    store: recoveryStore,
    initialState: encodedWorldState,
    reducer: { state, tick in
        try await reduceAuthoritativeTick(state: state, transitions: tick.transitions, randomDraws: tick.randomDraws)
    }
)

let recovered = await ticks.snapshot()
let profile = GameServerModeProfile.preset(.high)
let simulation = try profile.makeRealtimeSimulation(initialTick: recovered.lastCommittedTick)
let bridge = RedisDurableGameTickWriteAheadBridge(
    session: ticks,
    initialCommittedTick: recovered.lastCommittedTick,
    bridgeConfiguration: try .init(maximumPendingBatches: 32, maximumPendingBytes: 16_777_216),
    onDurableCommit: { batchID, receipt in
        // Filter the state for each recipient before publication; dedupe by batchID.
        try await publishCommittedState(receipt.state, revision: receipt.revision, batchID: batchID)
    },
    onWriterFailure: { await pauseSessionAdmission() }
)
let driver = try profile.makeRealtimeFixedStepDriver(simulation: simulation) { tick in
    // Application code creates server-authored transitions and records exact RNG draws.
    let durableTick = try encodeAuthoritativeTick(tick)
    try bridge.stage(RedisDurableGameTickBatch(ticks: [durableTick]))
}
await bridge.start()
await driver.start()
```

`RedisDurableGameTickWriteAheadBridge.stage(_:)` is synchronous, validates contiguous batches, and performs only bounded in-memory bookkeeping; it never actor-hops to Redis from the fixed-step callback. Its one serial worker commits batches off tick and invokes `onDurableCommit` only after append acknowledgement. That callback is the write-ahead publication boundary; use the batch ID to make publication/ack idempotent. Both count and retained bytes are capped. A stage or writer failure closes bridge admission; let stage errors escape the tick handler so `GameRealtimeFixedStepDriver` also fails closed. A failed/ambiguous commit remains the same in-flight batch and is retried with the same ID via `retryPending()`. Admission stays closed during retry: restore the latest committed state, resume `GameRealtimeSimulation` from `lastCommittedTick`, and use a new driver before accepting gameplay. `stop()` closes staging and drains a running writer; inspect its returned metrics because a failed writer can leave pending batches. The lower-level `makeBoundedQueue()` API remains available for applications that already have a separate async staging producer. Neither API captures transport packets, supplies game rules/transition decoders, or provides an external-effect outbox.

Tick numbers must continue from the last queued/committed tick; gaps, oversized records and non-contiguous batches fail closed. Limits cover application state bytes, transition size/count, tick count, random draws, batch bytes, replay work, retained batch IDs, pending batches and retained queue bytes. One journal revision counts one batch rather than one simulation tick. Do not drop transitions silently. On append failure, the committed snapshot and tick cursor remain unchanged. This API does not capture transport packets, supply simulation rules/transition decoders, or provide an external-effect outbox.

## Distributed matchmaking with PostgreSQL

For multiple game-server replicas sharing one queue, add the optional `PearfyGameServerMatchmakingPostgres` product. Apply the v2 migration from `PostgresGameMatchmakingQueue.migration(tablePrefix:)` through the app's versioned migration catalog, then construct every replica with the same `queueID`, table prefix, queue limits and `GameMatchmakingConfiguration`. Treat each queue ID as one server-defined pool, such as a playlist plus region, so the bounded candidate scan does not mix unrelated populations. Queue writes use a PostgreSQL transaction-scoped advisory lock per queue ID; keep this API in the matchmaking control plane and away from simulation ticks. A persisted per-queue cursor rotates the bounded candidate window so an unmatched head page cannot hide later compatible tickets on every claim; candidates inside each window are then planned in enqueue order. This prevents one source of starvation, but does not promise end-to-end fairness or maximum wait time.

`enqueue(_:)` expects the app to authenticate every player and validate mode, region and skill as server-owned values. `claimMatches(now:)` atomically reserves tickets and stores assignments before returning them. Pending assignments are delivered again with the same ID until `acknowledge(assignmentID:)` succeeds, so downstream room creation or Agones allocation must be idempotent by assignment ID and reconcile timeouts. `expireQueued(before:maximumTickets:)` expires only unassigned tickets. Schedule bounded `pruneHistory(before:maximumRowsPerTable:)` calls for terminal tickets and acknowledged assignments. Load-based fairness policy and actual server allocation remain application/deployment responsibilities.

For a bounded delivery loop, call `reconcilePendingAssignments(maximumAssignments:ensureAssignment:)`. The async callback runs after the claim transaction commits and before the separate acknowledgment transaction. A callback error leaves the assignment pending; a retry receives the same assignment ID. The queue actor avoids duplicate callback work within one instance, but replicas can still race, so the app callback must make room creation/allocation idempotent by assignment ID. The helper does not provide distributed allocation transactions or resolve unknown external outcomes by itself.

## Distributed MMO zones with PostgreSQL

Add the optional `PearfyGameServerWorldPostgres` product when replicas need shared zone authority and entity handoff. Apply `PostgresGameWorldLeaseStore.migration(tablePrefix:)`, then use identical `PostgresGameWorldConfiguration` bounds across replicas. Acquire each zone lease before admitting authoritative writes, renew it before expiry, and stop mutations if renewal fails. Expired takeovers advance the zone fencing epoch; create/update/remove and transfer operations verify both leases within their SQL transactions.

Entity creation, updates and transfers enforce active-zone count, per-zone entity count, per-entity bytes and aggregate zone bytes. Transfers lock both zone IDs in deterministic order and advance the entity fencing epoch. Reads are paginated to 500 records. Retire only empty zones to free active-zone capacity; retired zone IDs retain history and cannot be reused. Keep these PostgreSQL operations outside the simulation tick: this adapter provides control-plane leases and persistence, not simulation, interest management, snapshot/delta fanout, automatic lease renewal or multi-region recovery.

The UDP listener and matching `PearfyNetwork.SecureUDPTransport` are implemented and share a fixed cross-repository wire vector. `Integration/GameServerUDPInterop/run.sh` covers TLS join credential delivery and a real client/server datagram roundtrip. Keep production gameplay on WSS until Agones deployment and target-hardware abuse/performance controls are validated.

---
name: pearfy-gameserver-agones
description: Use for the optional Agones SDK sidecar lifecycle and mTLS allocator clients in dedicated Pearfy game server processes.
metadata:
  pearfy-module: gameserver-agones
  pearfy-skill-version: 1.1.0
---

# PearfyGameServerAgones

- Import `PearfyGameServerAgones` only for a game process running with the Agones SDK sidecar.
- Configure its dynamic `AGONES_SDK_HTTP_PORT`; the adapter only permits loopback sidecar hosts.
- Start the lifecycle health heartbeat while the app initializes. Call `ready()` only after the game transport and gameplay state are initialized.
- `AgonesAllocatorClient` allocates through the external Agones Allocator Service with mTLS, full server certificate verification, a bounded request/response, a deadline and one attempt. Configure its client certificate, private key, trusted server CA, namespace and DNS `serverName`; IP endpoints require a DNS name covered by the server certificate. Do not automatically retry an allocation because a timeout can leave its outcome ambiguous.
- `allocate()` on `AgonesSDKLifecycle` calls SDK Allocate for application-owned allocation flows. Prefer `AgonesAllocatorClient` for ordinary Fleet scheduling; it delegates selection and atomic allocation to Agones.
- `gameServer()` returns a bounded projection of SDK GameServer state. Agones lifecycle changes are asynchronous and eventually consistent.
- `stop()` drains the local heartbeat task and calls SDK Shutdown after readiness/allocation. Do not treat an accepted SDK command as proof of a cluster-wide allocation or readiness observation.
- The allocator client does not use Kubernetes credentials or call the Kubernetes API. Fleet deployment, application matchmaking and global placement policy remain application/deployment responsibilities.

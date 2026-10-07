# gRPC/TLS control plane

## Implemented contract

`PearfyGameServerGRPC` is an opt-in product. Its versioned protobuf files define the service names required by PearfyEngine:

| gRPC method | Owner callback |
| --- | --- |
| `pearfy.matchmaking.v1.Matchmaking/FindGame` | `.findGame` |
| `pearfy.matchmaking.v1.Matchmaking/CreateRoom` | `.createRoom` |
| `pearfy.game.v1.GameSession/Join` | `.join` |
| `pearfy.game.v1.GameSession/Leave` | `.leave` |

The common request/response envelope contains `bytes payload`. These bytes are the application's protobuf-serialized message. The server transport does not inspect or log them; the application defines the domain schema and validates it. Keep payload definitions versioned and shared with PearfyNetwork. `GameServerGRPCServer.Dispatch` returns the serialized response bytes for the same endpoint.

## Security and resource bounds

- TLS is mandatory. Configure a PEM certificate chain and matching key; ALPN is required.
- Exactly one bounded `authorization: Bearer …` metadata value is required. The async application callback validates the ticket and returns the session/player/protocol principal.
- Request and response payload bytes are bounded; the HTTP/2 decoder also caps encoded request bytes. Configuration validates that the worst-case payload budget across all allowed connections and streams fits the aggregate in-flight payload ceiling.
- The listener rejects connections above the configured hard cap and limits concurrent streams per connection.
- `stop()` refuses new calls and waits for calls already accepted to drain.
- Authentication errors map to `UNAUTHENTICATED`, oversized messages to `RESOURCE_EXHAUSTED`; arbitrary app errors become generic `INTERNAL` errors. Never log credentials, raw metadata, or payloads.

The gRPC Swift 2 runtime marks its Apple APIs available at macOS 15/iOS 18. The POSIX transport is intended for dedicated Linux processes as well as Darwin. This module does not manage ticket storage, matchmaking, rooms, game simulation, HTTP health checks or UDP.

## Validation gates

- `swift build --target PearfyGameServerGRPC`
- `swift test --filter gameServerGRPCUnaryControl`
- `pearfy guardian verify`
- Consumer integration against PearfyEngine `PearfyNetwork` and its actual ticket/payload policy before deployment.

The local integration test uses an ephemeral self-signed certificate and the generated gRPC Swift client, verifies unary response bytes and verifies that a missing bearer value is rejected. It validates transport/wire interoperability, not application policy or production certificate deployment.

## Upstream references

- [gRPC Swift 2](https://github.com/grpc/grpc-swift-2)
- [gRPC Swift NIO HTTP/2 transport](https://github.com/grpc/grpc-swift-nio-transport)
- [gRPC Swift protobuf code generation](https://github.com/grpc/grpc-swift-protobuf)
- Companion protocol source: `pearfy-engine/Documentation/GameServerTransportIntegration.md` in the PearfyEngine repository.

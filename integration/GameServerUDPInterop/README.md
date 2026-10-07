# GameServer UDP interoperability test

This isolated SwiftPM test package proves the real control-plane and client-to-server path across the Pearfy and PearfyEngine checkouts. It exercises a TLS gRPC join with bearer-ticket validation and channel-key response, then uses the returned per-player channel and key with `PearfyNetwork.SecureUDPTransport` against the Pearfy NIO UDP listener. A burst test also verifies the server dispatches no more than the configured per-player work budget and keeps separate players' budgets independent.

Run it on macOS from the Pearfy checkout:

```sh
Integration/GameServerUDPInterop/run.sh
```

The script temporarily links the sibling `../pearfy-engine/Sources/PearfyNetwork` sources into the test package, runs SwiftPM, and removes the link. It does not add PearfyEngine as a runtime dependency of Pearfy. The TLS join case validates delivery over the authenticated control plane; the harness uses a local test certificate and does not replace deployment certificate validation or production load testing.

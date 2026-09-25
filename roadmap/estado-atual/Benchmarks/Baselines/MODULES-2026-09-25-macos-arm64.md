# In-process module microbenchmarks — 2026-09-25

- Host: MacBook Air, Apple M4, 16 GiB RAM, arm64.
- OS: macOS 27.0 (Build 26A5425a).
- Toolchain: Apple Swift 6.4.0.34.1.
- Build: SwiftPM release.
- Source revision: `ce5bef0` (initial local baseline commit).
- Capture: 5 runs, 1,000 operations per loop, except scheduler lifecycle (one start/stop per run).
- Workloads are in-process: cache operations and message ack use bounded local adapters; outbound HTTP uses a stub transport and no network; metrics increments use the local registry.
- Peak RSS is process-wide high-water RSS, cumulative across scenarios.
- Raw output: `MODULES-2026-09-25-macos-arm64.csv`.

| Module | Scenario | Operations | Median |
|---|---|---:|---:|
| `PearfyCache` | cached lookup | 1,000 | 1.344 ms |
| `PearfyCache` | write/read | 1,000 | 2.643 ms |
| `PearfyMessaging` | publish/receive/ack | 1,000 | 0.630 ms |
| `PearfyCloud` | outbound HTTP client with stub | 1,000 | 1.100 ms |
| `PearfyObservability` | counter increment | 1,000 | 0.198 ms |
| `PearfyJobs` | empty scheduler start/stop | 1 | 0.004 ms |

These are microbenchmarks of local APIs, not estimates for Redis, PostgreSQL, a real broker, network HTTP, or production workloads.

Reproduce with:

```bash
bash scripts/benchmark-modules.sh --runs 5 --resolves 1000 --concurrency 10
```

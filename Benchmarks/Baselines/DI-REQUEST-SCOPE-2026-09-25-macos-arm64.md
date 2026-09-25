# Request scope and lifecycle baseline — 2026-09-25

- Host: MacBook Air, Apple M4, 16 GiB RAM, arm64.
- OS: macOS 27.0 (Build 26A5425a).
- Toolchain: Apple Swift 6.4.0.34.1.
- Build: SwiftPM release.
- Source revision: `ce5bef0` (initial local baseline commit).
- Capture: 5 timed samples per scenario; raw rows are adjacent.
- Peak RSS is the process high-water mark and cumulative across scenarios; it is not RSS attributed to one operation.

| Scenario | Operations | Median | Peak RSS observed | Factory calls |
|---|---:|---:|---:|---:|
| Cached resolution within one request scope | 10,000 | 8.804 ms | 10,715,136 B | 1 |
| Create, resolve, and close request scopes | 1,000 | 3.823 ms | 10,715,136 B | 1,000 |
| Empty application context start/stop | 1 | 0.001 ms | 10,731,520 B | 0 |

The unit tests additionally verify concurrent coalescing, distinct instances across scopes, closed-scope rejection, and that `close()` releases a cached reference. These local measurements are a baseline, not an SLA.

Reproduce with:

```bash
bash scripts/benchmark-di.sh --runs 5 --registrations 10,100,1000 --resolves 10000 --concurrency 100
```

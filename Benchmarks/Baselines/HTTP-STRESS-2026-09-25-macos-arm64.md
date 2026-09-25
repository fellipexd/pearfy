# HTTP high-load run — 2026-09-25

- Source revision: `ce5bef0` (initial local baseline commit).
- Host: MacBook Air, Apple M4, 16 GiB RAM, arm64; macOS 27.0 (26A5425a).
- Toolchain: Apple Swift 6.4.0.34.1; SwiftPM release.
- Workload: 20,000 requests/sample, 2 runs, plaintext and JSON, concurrency 1/10/100, SwiftNIO bare vs. Pearfy/NIO.
- Total measured requests: 480,000; every sample returned zero errors.
- Raw rows and medians: `HTTP-STRESS-2026-09-25-macos-arm64.csv`.
- Peak RSS is the benchmark process high-water mark and is cumulative across server/scenario runs.

## Median throughput (RPS)

| Scenario | Concurrency | SwiftNIO bare | Pearfy/NIO | Delta |
|---|---:|---:|---:|---:|
| Plaintext | 1 | 6,640.629 | 5,944.826 | −10.5% |
| Plaintext | 10 | 15,119.147 | 14,491.844 | −4.1% |
| Plaintext | 100 | 15,302.799 | 14,711.467 | −3.9% |
| JSON | 1 | 6,571.131 | 5,880.728 | −10.5% |
| JSON | 10 | 14,836.000 | 14,124.485 | −4.8% |
| JSON | 100 | 14,772.767 | 14,281.826 | −3.3% |

This is a local two-run stress comparison, not a long-duration soak or an SLA. A separate `/usr/bin/sample` CPU capture while the benchmark was handling requests included `HTTPRouter.handle`, middleware dispatch, path matching, and `JSONEncoder.encode`; no optimization was accepted from a single profile. The temporary host profile is not part of the source baseline.

Reproduce with:

```bash
bash scripts/benchmark-http.sh --runs 2 --http-requests 20000
```

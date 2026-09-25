# HTTP metrics overhead baseline — 2026-09-25

- Host: MacBook Air, Apple M4, 16 GiB RAM, arm64.
- OS: macOS 27.0 (Build 26A5425a).
- Toolchain: Apple Swift 6.4.0.34.1.
- Build: SwiftPM release.
- Source revision: `ce5bef0` (initial local baseline commit).
- Workload: Pearfy router/NIO with middleware off vs. `HTTPMetricsMiddleware` on; 500 requests/sample, 5 samples, plaintext and JSON, concurrency 1/10/100.
- All 60 samples reported zero errors. Peak RSS is process-wide high-water RSS across both server runs, not per-server attribution.
- Raw samples and medians: `HTTP-OBSERVABILITY-2026-09-25-macos-arm64.csv`.

## Median throughput delta with metrics enabled

| Scenario | Concurrency | Metrics off RPS | Metrics on RPS | Delta |
|---|---:|---:|---:|---:|
| Plaintext | 1 | 5,747.837 | 5,717.586 | −0.5% |
| Plaintext | 10 | 13,423.254 | 13,167.785 | −1.9% |
| Plaintext | 100 | 13,661.949 | 13,458.180 | −1.5% |
| JSON | 1 | 5,745.998 | 5,629.637 | −2.0% |
| JSON | 10 | 13,636.859 | 13,281.344 | −2.6% |
| JSON | 100 | 13,577.333 | 13,547.657 | −0.2% |

This measures the current in-memory HTTP metrics middleware only; tracing and structured logging are not implemented, so `PPERF-OBS-002` remains open. Results are local observations, not an SLA.

Reproduce with `bash scripts/benchmark-observability.sh --runs 5 --http-requests 500` on the same host/toolchain.

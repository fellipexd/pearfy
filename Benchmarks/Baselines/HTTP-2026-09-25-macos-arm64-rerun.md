# HTTP baseline rerun — 2026-09-25

- Host: MacBook Air, Apple M4, 16 GiB RAM, arm64.
- OS: macOS 27.0 (Build 26A5425a).
- Toolchain: Apple Swift 6.4.0.34.1.
- Build: SwiftPM release.
- Source revision: `unversioned-worktree` (the checkout has no Git repository).
- Workload: 500 requests per sample; 5 samples; plaintext and JSON; concurrency 1/10/100; URLSession client.
- All 60 samples reported zero errors. Peak RSS is the high-water mark of the benchmark process, including both server runs.
- Raw data: `HTTP-2026-09-25-macos-arm64-rerun.csv`.

## Median RPS (bare SwiftNIO → Pearfy router + NIO)

| Scenario | Concurrency | SwiftNIO | Pearfy | Throughput delta |
|---|---:|---:|---:|---:|
| Plaintext | 1 | 6,508.711 | 5,800.341 | −10.9% |
| Plaintext | 10 | 14,703.864 | 14,008.856 | −4.7% |
| Plaintext | 100 | 14,784.151 | 14,187.852 | −4.0% |
| JSON | 1 | 6,697.471 | 5,850.665 | −12.6% |
| JSON | 10 | 14,578.251 | 14,029.345 | −3.8% |
| JSON | 100 | 15,037.914 | 14,393.684 | −4.3% |

The single-worker JSON/plaintext cases are outside the suggested 10% observation band; this is diagnostic data, not an SLA or a universal ranking. Reproduce with `bash scripts/benchmark-http.sh --runs 5 --http-requests 500` on the same host/toolchain.

# HTTP baseline — 2026-09-25

- Host: MacBook Air, Apple M4, 16 GiB RAM, arm64.
- OS/toolchain: macOS 27.0 (26A5425a), Apple Swift 6.4.0.34.1.
- Build: SwiftPM `release`; five 500-request samples per route/concurrency point.
- Comparators use identical plaintext (`pear`) and JSON (`{"message":"pear"}`) payloads on loopback, with keep-alive and no external database.
- Source revision: `ce5bef0` (initial local baseline commit).
- All recorded samples returned 200 with zero body/status mismatches. RPS, p95/p99, and RSS are local exploratory measurements, not a product promise.

## Medianas

| Server | Route | Concorrência | RPS | p95 ms | p99 ms | Peak RSS B |
|---|---|---:|---:|---:|---:|---:|
| SwiftNIO bare | plaintext | 1 | 6,334.6 | 0.179 | 0.341 | 18,169,856 |
| Pearfy/NIO | plaintext | 1 | 5,688.8 | 0.198 | 0.426 | 22,986,752 |
| SwiftNIO bare | plaintext | 10 | 13,775.4 | 1.128 | 1.399 | 19,136,512 |
| Pearfy/NIO | plaintext | 10 | 13,368.5 | 1.087 | 1.330 | 23,216,128 |
| SwiftNIO bare | plaintext | 100 | 14,307.4 | 9.731 | 10.862 | 21,233,664 |
| Pearfy/NIO | plaintext | 100 | 13,188.2 | 10.040 | 12.035 | 23,494,656 |
| SwiftNIO bare | JSON | 1 | 6,471.7 | 0.172 | 0.380 | 21,479,424 |
| Pearfy/NIO | JSON | 1 | 5,699.3 | 0.199 | 0.431 | 23,609,344 |
| SwiftNIO bare | JSON | 10 | 13,990.5 | 1.144 | 1.381 | 21,676,032 |
| Pearfy/NIO | JSON | 10 | 13,581.2 | 1.104 | 1.269 | 23,609,344 |
| SwiftNIO bare | JSON | 100 | 14,434.4 | 9.544 | 10.813 | 22,118,400 |
| Pearfy/NIO | JSON | 100 | 13,620.5 | 9.382 | 10.757 | 23,740,416 |

O conjunto de dados completo, incluindo as cinco amostras, está em `HTTP-2026-09-25-macos-arm64.csv`. Reproduza com:

```bash
bash scripts/benchmark-http.sh --runs 5 --http-requests 500 > http-baseline.csv 2> http-baseline-metadata.txt
```

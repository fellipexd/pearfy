# DI lookup index experiment — 2026-09-25

- Host/toolchain/build: same MacBook Air M4, macOS 27.0, Swift 6.4 release configuration as `DI-2026-09-25-macos-arm64.md`.
- Five samples per point. The operation count is scaled to keep the original linear-scan baseline bounded: `min(--resolves, max(100, 100000 / registration-count))`.
- CSV files next to this report contain the raw samples and medians before/after the type index.
- `peak_rss_bytes` remains process-wide high-water RSS, not scenario-attributed memory.

| Registrations of one type | Qualified scan before | Qualified indexed after | Primary scan before | Primary indexed after |
|---:|---:|---:|---:|---:|
| 10 | 11.011 µs/resolve | 1.497 µs/resolve | 9.290 µs/resolve | 1.544 µs/resolve |
| 100 | 468.990 µs/resolve | 1.639 µs/resolve | 411.643 µs/resolve | 1.764 µs/resolve |
| 1,000 | 6,640.560 µs/resolve | 2.100 µs/resolve | 6,927.480 µs/resolve | 2.060 µs/resolve |

The indexed implementation maintains a per-type key table and a cached default/primary key. Qualified lookup uses the full `(type, qualifier)` key directly; ambiguous candidates are sorted only when constructing the diagnostic. Registration build medians for 1,000 bindings were 9.379 ms before and 9.967 ms after, within the small single-host variance observed here. This is evidence for this lookup hotspot only, not a general framework performance claim.

# HTTP heap snapshot — 2026-09-25

- Source revision: `ce5bef0` (initial local baseline commit).
- Host: MacBook Air, Apple M4, 16 GiB RAM, arm64; macOS 27.0 (26A5425a).
- Toolchain: Apple Swift 6.4.0.34.1; SwiftPM release.
- Workload: `pearfy-bench --http-only --runs 1 --http-requests 30000`; heap snapshot taken 20 seconds after launch while the HTTP comparison was running.
- Capture: `/usr/bin/heap -q -H -s --noContent <pid>` with `MallocStackLogging=lite` enabled in the target process.
- Snapshot: 8,890 malloc nodes / 2,236 KiB across the benchmark process; allocation backtraces named 151 non-object types.

The process includes both server implementations, URLSession clients, and the benchmark's latency arrays; this is a retained heap snapshot, not allocations/request or server-only memory. It contained seven `ByteBuffer._Storage._bytes` allocations totaling about 15 KiB, one 28 KiB `PooledBuffer.BackingStorage`, and two 240 KiB `Array<Double>` latency stores. No large repeated response-buffer copy was isolated, so this run does not justify a buffer-pooling change. Dedicated allocation attribution for a production-like JSON route remains open under `PPERF-MEM-001`.

Reproduce from the package root:

```bash
MallocStackLogging=lite .build/release/pearfy-bench --http-only --runs 1 --http-requests 30000 >/dev/null &
target_pid=$!
sleep 20
heap -q -H -s --noContent "$target_pid"
wait "$target_pid"
```

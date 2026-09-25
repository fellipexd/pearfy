# HTTP soak and shutdown — 2026-09-25

- Source revision: `ce5bef0` (initial local baseline commit).
- Host: MacBook Air, Apple M4, 16 GiB RAM, arm64; macOS 27.0 (26A5425a).
- Target: generated `pearfy new` scaffold, Debug build, `GET /hello/pear`.
- Workload: 60 seconds, 16 persistent HTTP/1.1 workers; RSS sampled once per second.
- Requests before shutdown: 952,223 correct HTTP 200 responses, zero unexpected responses, zero client errors.
- Memory: peak and final sampled RSS 13,808 KB.
- Shutdown: SIGTERM sent while workers were active; process exited with status 0. The client observed 626 connection errors during the expected listener shutdown window.

Reproduce after building a scaffold:

```bash
tmp_dir="$(mktemp -d)"
.build/release/pearfy new PearfySoak --path "$tmp_dir/PearfySoak"
swift build --package-path "$tmp_dir/PearfySoak"
python3 scripts/soak-http.py \
  --target "$tmp_dir/PearfySoak/.build/debug/PearfySoak" \
  --duration-seconds 60 --workers 16
```

This is a local NIO/router soak for shutdown and RSS behavior, not a production SLO or a long-duration cache/task-retention audit.

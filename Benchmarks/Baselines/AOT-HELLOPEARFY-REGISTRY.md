# Generated target registry snapshot

This sample snapshots the actual `PearfyGeneratedRegistry.swift` emitted for `HelloPearfy` by `PearfyDiscoveryPlugin` in the current checkout. It shows the target-local, explicit factory calls; no runtime type scan is involved.

- Toolchain: Apple Swift 6.4.0.34.1.
- Target: `HelloPearfy`.
- Source revision: `ce5bef0` (initial local baseline commit).
- Generated source: `AOT-HELLOPEARFY-REGISTRY.swift`.

Regenerate and compare with `bash scripts/verify-aot-snapshot.sh`; SwiftPM writes the plugin output under `.build/plugins/outputs/`. The checked-in-style snapshot is an inspection baseline, not a build input. The snapshot is versioned and the generation check passes for `PPERF-AOT-001`.

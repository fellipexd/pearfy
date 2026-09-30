# Metric with Guardian

**Status: partial primitives only.** `PearfyObservability` has health/readiness and Prometheus metrics. The separate `PearfyMetric` analysis module and Guardian policy gates are not implemented; current Guardian covers build, unit tests and declared service environment only.

Use observed metrics in tests/benchmarks without calling them PearfyMetric analytics. A Guardian PASS cannot be inferred from an agent report; run its CLI and report INCOMPLETE for unavailable gates.

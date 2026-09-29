# DevKit dashboard reference

- Product and API implementation: `Sources/PearfyDevKitUI/DevKitUI.swift`; integration/configuration examples: `docs/PEARFY-DEVKIT-UI.md`.
- Install through Module Manager, call `PearfyDevKitUI.install(on:configuration:source:)` before router freeze, and pass an explicit secret-backed bearer token.
- The built-in metrics adapter accepts only the HTTP counter/histogram names and method/template pairs found in the router. It labels process lifetime and reports that the selected window was not applied.
- Installing DevKit adds a 512-entry in-process request trace ring for route templates, methods, status codes and durations, plus a bounded recorder for explicitly reported background work; the selected time window is applied to both samples. `/api/errors` derives sanitized 4xx/5xx events correlated by trace ID. Concrete paths, query values, headers, bodies and exception messages are never captured.
- The tracing middleware sets `HTTPRequest.traceIDContextKey` and `HTTPRequest.spanIDContextKey` before later middleware and route handlers run, so application-owned redacted logs can correlate with the dashboard trace.
- `DevKitTelemetryRuntime.workTraceRecorder` records safe work names, duration and `ok`/`error` outcome only. `JobScheduler` exposes an execution observer that applications can connect to this recorder; unconnected schedulers do not emit work traces.
- `DevKitSnapshotSource` remains the extension point for richer/distributed spans, redacted logs, normalized query aggregates and host metrics.
- Do not treat the approved design prototype or roadmap MCP manifest as a live collector/tool implementation.

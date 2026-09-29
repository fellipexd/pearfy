# PearfyDevKitUI v1.7

`PearfyDevKitUI` is an optional, read-only development dashboard. It is disabled unless the application explicitly installs it, requires a bearer token whenever enabled, and never records request bodies, cookies, authorization headers, SQL bindings, or credentials.

## Install and enable

Add the `Pearfy` package dependency and the `PearfyDevKitUI` and
`PearfyObservability` products to the application target. Register the dashboard
before the HTTP router is frozen. Keep the server bound to loopback for local use
and load the token from a local secret/environment source:

```swift
import PearfyObservability
import PearfyDevKitUI
import PearfyPostgres

try await PearfyDevKitUI.install(
    on: router,
    configuration: DevKitConfiguration(
        enabled: ProcessInfo.processInfo.environment["PEARFY_DEVKIT_ENABLED"] == "true",
        environment: .development,
        bearerToken: ProcessInfo.processInfo.environment["PEARFY_DEVKIT_TOKEN"],
        serviceName: "my-service",
        instanceID: ProcessInfo.processInfo.environment["PEARFY_INSTANCE_ID"]
    )
)
```

Tokens must contain 16–256 printable ASCII characters. The page is served at `/__pearfy/devkit`; its read-only JSON endpoints are protected with the same bearer token. The dashboard assets use a restrictive content-security policy. After a successful connection, the browser saves the token in origin-scoped local storage; **Disconnect** removes it.

## Existing HTTP metrics

The metrics adapter exposes only `pearfy_http_requests_total` and `pearfy_http_request_duration_seconds`, and only for method/template pairs present in the live route registry. Other metric names and labels are not sent to the dashboard.

```swift
let httpMetrics = MetricsRegistry()
try await router.use(HTTPMetricsMiddleware.make(registry: httpMetrics))
try await PearfyDevKitUI.install(
    on: router,
    configuration: configuration,
    source: .httpMetrics(httpMetrics, router: router)
)
```

The existing `.httpMetrics` adapter without a runtime remains cumulative for the process lifetime and reports that its requested window was not applied. For rolling in-process HTTP metrics, process resources, and work traces, use a shared `DevKitTelemetryRuntime`:

```swift
let runtime = DevKitTelemetryRuntime()
let source = try await runtime.install(on: router, configuration: devKitConfiguration)
try await PearfyDevKitUI.install(on: router, configuration: devKitConfiguration, source: source)
```

The runtime collects route-template HTTP metrics in rolling one-minute buckets with 24-hour retention and samples process CPU over one-second intervals and current resident memory. Integrations can use its bounded `telemetryStore` to record query aggregates. The store uses process-keyed HMAC fingerprints and never exposes SQL statements or bind values. Logs must be structured and redacted before they are provided. Valid W3C `traceparent` context is continued. `DevKitTrace.kind` classifies `.request` and `.work` traces for separate dashboard sections; older payloads infer the kind from their method and route fields. `JobScheduler` can publish completed named-work timing and outcomes through its execution observer; `DevKitWorkTraceRecorder` retains a bounded sample without exception details or work payloads. When a route has no calls in the selected window its count is zero and latency is shown as no sample; percentiles are estimated from histogram buckets. Route entries always come from the actual router registry, and the UI hides zero-traffic routes by default with an option to show all registered routes.

## Available endpoints

- `GET /__pearfy/devkit/api/overview?window=15m`
- `GET /__pearfy/devkit/api/routes?window=15m`
- `GET /__pearfy/devkit/api/traces?window=15m`
- `GET /__pearfy/devkit/api/errors?window=15m`
- `GET /__pearfy/devkit/api/logs?window=15m`
- `GET /__pearfy/devkit/api/instances?window=15m`
- `GET /__pearfy/devkit/api/queries?window=15m`

Supported windows are `15m`, `1h`, and `24h`; providers indicate whether the requested window was actually applied. Instance filtering is available to providers that publish per-instance data. A missing provider produces empty results, never demo values.

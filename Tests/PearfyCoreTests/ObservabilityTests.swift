import Foundation
import PearfyObservability
import PearfyWeb
import Testing

@Test func metricsRegistryBoundsCardinalityAndExportsCountersAndHistograms() async throws {
    let registry = MetricsRegistry(maximumSeries: 2, maximumLabelsPerSeries: 2)
    let labels = try MetricLabels(["method": "get", "route": "/users/{id}"])
    try await registry.increment("pearfy_http_requests_total", labels: labels)
    try await registry.observe("pearfy_http_request_duration_seconds", value: 0.01, labels: labels)
    let output = await registry.prometheusText()
    #expect(output.contains("pearfy_http_requests_total{method=\"get\",route=\"/users/{id}\"} 1"))
    #expect(output.contains("pearfy_http_request_duration_seconds_bucket"))
    #expect(output.contains("pearfy_http_request_duration_seconds_count{method=\"get\",route=\"/users/{id}\"} 1"))

    let newLabels = try MetricLabels(["method": "post", "route": "/users"])
    var cardinalityRejected = false
    do {
        try await registry.increment("pearfy_http_requests_total", labels: newLabels)
    } catch MetricsError.cardinalityLimit {
        cardinalityRejected = true
    }
    #expect(cardinalityRejected)
}

@Test func metricsRejectUnboundedLabelValues() throws {
    var rejected = false
    do {
        _ = try MetricLabels(["route": String(repeating: "x", count: 1_025)])
    } catch MetricsError.labelValueTooLong(1_024) {
        rejected = true
    }
    #expect(rejected)
}

@Test func httpMetricsUseRouteTemplatesInsteadOfConcretePathValues() async throws {
    let registry = MetricsRegistry()
    let router = HTTPRouter()
    try await router.use(HTTPMetricsMiddleware.make(registry: registry))
    try await router.get("/users/{id}") { _ in .text("ok") }
    try await router.freeze()

    let request = try HTTPRequest(method: .get, target: "/users/12345")
    let response = await router.handle(request)
    let output = await registry.prometheusText()
    #expect(response.status == 200)
    #expect(output.contains("route=\"/users/{id}\""))
    #expect(!output.contains("12345"))
}

@Test func httpMetricsTrackInFlightRequestsAndReturnGaugeToZero() async throws {
    let registry = MetricsRegistry()
    let router = HTTPRouter()
    try await router.use(HTTPMetricsMiddleware.make(registry: registry))
    try await router.get("/slow") { _ in
        let duringRequest = await registry.prometheusText()
        #expect(duringRequest.contains("pearfy_http_requests_in_flight{method=\"get\",route=\"/slow\"} 1.0"))
        try await Task.sleep(for: .milliseconds(5))
        return .text("done")
    }
    try await router.freeze()

    let response = await router.handle(try HTTPRequest(method: .get, target: "/slow"))
    let afterRequest = await registry.prometheusText()
    #expect(response.status == 200)
    #expect(afterRequest.contains("pearfy_http_requests_in_flight{method=\"get\",route=\"/slow\"} 0.0"))
}

@Test func readinessRoutesReflectApplicationStateAndHealthChecks() async throws {
    let health = HealthRegistry()
    try await health.register("database") { .healthy }
    let readiness = ReadinessGate()
    let router = HTTPRouter()
    try await HealthRoutes.install(on: router, registry: health, readiness: readiness)
    try await router.freeze()

    let request = try HTTPRequest(method: .get, target: "/health/ready")
    #expect(await router.handle(request).status == 503)
    await readiness.markReady()
    #expect(await router.handle(request).status == 200)
    #expect(await readiness.state == .ready)
}

@Test func healthMetricsEndpointIsAuthenticatedByDefault() async throws {
    let router = HTTPRouter()
    try await HealthRoutes.install(
        on: router,
        registry: HealthRegistry(),
        readiness: ReadinessGate(),
        metrics: MetricsRegistry()
    )
    try await router.freeze()
    let request = try HTTPRequest(method: .get, target: "/metrics")
    #expect(await router.handle(request).status == 401)
}

@Test func slowHealthCheckTimesOutWithoutBlockingReadinessEvaluation() async throws {
    let registry = HealthRegistry()
    try await registry.register("slow") {
        try await Task.sleep(for: .seconds(2))
        return .healthy
    }
    let clock = ContinuousClock()
    let start = clock.now
    let report = await registry.evaluate(timeoutPerCheck: .milliseconds(10))
    let elapsed = start.duration(to: clock.now)

    #expect(report.status == .unhealthy)
    #expect(elapsed < .seconds(1))
}

@Test func healthRegistryRejectsUnboundedOrUnsafeCheckNames() async throws {
    let registry = HealthRegistry()
    var rejected = false
    do {
        try await registry.register("database password") { .healthy }
    } catch HealthRegistryError.invalidName {
        rejected = true
    }
    #expect(rejected)
}

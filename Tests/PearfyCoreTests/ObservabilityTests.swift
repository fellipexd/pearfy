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
    let snapshot = await registry.snapshot()
    #expect(snapshot.first(where: { $0.name == "pearfy_http_requests_total" })?.counterValue == 1)
    let histogram = snapshot.first(where: { $0.name == "pearfy_http_request_duration_seconds" })?.histogram
    #expect(histogram?.count == 1)
    #expect(histogram?.upperBounds.last?.isInfinite == true)

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
    let telemetry = InProcessTelemetryStore()
    let fingerprint = await telemetry.fingerprint(forSQL: "SELECT * FROM users WHERE id = $1")
    let router = HTTPRouter()
    try await router.use(HTTPMetricsMiddleware.make(registry: registry, telemetry: telemetry))
    try await router.get("/users/{id}") { _ in
        await telemetry.recordDatabaseQuery(
            fingerprint: fingerprint,
            routeTemplate: TelemetryTaskContext.routeTemplate,
            durationMilliseconds: 1,
            failed: false
        )
        return .text("ok")
    }
    try await router.freeze()

    let request = try HTTPRequest(method: .get, target: "/users/12345")
    let response = await router.handle(request)
    let output = await registry.prometheusText()
    #expect(response.status == 200)
    #expect(output.contains("route=\"/users/{id}\""))
    #expect(!output.contains("12345"))
    let snapshot = await telemetry.snapshot(windowSeconds: 15 * 60)
    #expect(snapshot.requestCount == 1)
    #expect(snapshot.routeMetrics.first?.routeTemplate == "/users/{id}")
    #expect(snapshot.queryMetrics.first?.routeTemplate == "/users/{id}")
    #expect(!String(describing: snapshot).contains("12345"))
}

@Test func inProcessTelemetryAppliesRollingWindowsAndRedactsDatabaseFailures() async throws {
    let telemetry = InProcessTelemetryStore()
    let now = Date()
    await telemetry.recordHTTP(
        method: "GET",
        routeTemplate: "/users/{id}",
        statusCode: 404,
        durationMilliseconds: 8,
        timestamp: now.addingTimeInterval(-3_600)
    )
    await telemetry.recordHTTP(
        method: "GET",
        routeTemplate: "/users/{id}",
        statusCode: 200,
        durationMilliseconds: 12,
        timestamp: now.addingTimeInterval(-20)
    )
    await telemetry.recordHTTP(
        method: "GET",
        routeTemplate: "/users/{id}",
        statusCode: 500,
        durationMilliseconds: 32,
        timestamp: now.addingTimeInterval(-10)
    )

    let statement = "SELECT * FROM users WHERE email = 'private@example.com'"
    let fingerprint = await telemetry.fingerprint(forSQL: statement)
    await telemetry.recordDatabaseQuery(
        fingerprint: fingerprint,
        durationMilliseconds: 18,
        failed: false,
        timestamp: now.addingTimeInterval(-15)
    )
    await telemetry.recordDatabaseQuery(
        fingerprint: fingerprint,
        durationMilliseconds: 38,
        failed: true,
        timestamp: now.addingTimeInterval(-5)
    )

    let snapshot = await telemetry.snapshot(windowSeconds: 15 * 60, now: now)
    #expect(snapshot.requestCount == 2)
    #expect(snapshot.errorCount == 1)
    #expect(snapshot.routeMetrics.first?.requestCount == 2)
    #expect(snapshot.routeMetrics.first?.errorCount == 1)
    #expect(snapshot.queryMetrics.count == 1)
    #expect(snapshot.queryMetrics.first?.executionCount == 2)
    #expect(snapshot.queryMetrics.first?.errorCount == 1)
    #expect(!fingerprint.contains("private@example.com"))
    #expect(!String(describing: snapshot).contains("private@example.com"))
    #expect(snapshot.logs.contains { $0.message == "PostgreSQL query failed" })
    #expect(snapshot.logs.contains { $0.message == "HTTP request completed with status 500" })
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

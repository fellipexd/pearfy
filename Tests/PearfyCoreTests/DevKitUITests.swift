import Foundation
import PearfyDevKitUI
import PearfyJobs
import PearfyObservability
import PearfyWeb
import Testing

@Test func devKitIsOptInAndLeavesNormalApplicationRoutesAvailable() async throws {
    let router = HTTPRouter()
    try await router.get("/users/{id}") { _ in .text("ok") }
    try await PearfyDevKitUI.install(on: router)
    try await router.freeze()

    let applicationResponse = await router.handle(try HTTPRequest(method: .get, target: "/users/123"))
    let dashboardResponse = await router.handle(try HTTPRequest(method: .get, target: "/__pearfy/devkit"))
    #expect(applicationResponse.status == 200)
    #expect(dashboardResponse.status == 404)
}

@Test func devKitShowsTemplatedRoutesAndAllowlistedRealHTTPMetrics() async throws {
    let router = HTTPRouter()
    let metrics = MetricsRegistry()
    try await router.use(HTTPMetricsMiddleware.make(registry: metrics))
    try await router.get("/users/{id}") { _ in .text("ok") }
    try await PearfyDevKitUI.install(
        on: router,
        configuration: DevKitConfiguration(
            enabled: true,
            environment: .development,
            bearerToken: "local-devkit-token-1234",
            serviceName: "test-api",
            instanceID: "api-local-1"
        ),
        source: .httpMetrics(metrics, router: router)
    )
    try await router.freeze()

    let requestResponse = await router.handle(try HTTPRequest(method: .get, target: "/users/concrete-secret-id"))
    #expect(requestResponse.status == 200)

    let unauthorized = await router.handle(try HTTPRequest(method: .get, target: "/__pearfy/devkit/api/routes"))
    #expect(unauthorized.status == 401)

    let headers = ["authorization": "Bearer local-devkit-token-1234"]
    let routesResponse = await router.handle(try HTTPRequest(method: .get, target: "/__pearfy/devkit/api/routes", headers: headers))
    #expect(routesResponse.status == 200)
    let routes = try #require(JSONSerialization.jsonObject(with: routesResponse.body) as? [[String: Any]])
    let route = try #require(routes.first { $0["pathTemplate"] as? String == "/users/{id}" })
    #expect(route["pathTemplate"] as? String == "/users/{id}")
    #expect(routesResponse.body.range(of: Data("concrete-secret-id".utf8)) == nil)
    let routeMetrics = try #require(route["metrics"] as? [String: Any])
    #expect(routeMetrics["requestCount"] as? Int == 1)

    let overviewResponse = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/api/overview?window=1h",
        headers: headers
    ))
    #expect(overviewResponse.status == 200)
    let overviewDocument = try #require(JSONSerialization.jsonObject(with: overviewResponse.body) as? [String: Any])
    #expect(overviewDocument["serviceName"] as? String == "test-api")
    let overview = try #require(overviewDocument["overview"] as? [String: Any])
    #expect(overview["windowApplied"] as? Bool == false)
    #expect(overview["requestCount"] as? Int == 1)

    let queriesResponse = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/api/queries",
        headers: headers
    ))
    #expect(queriesResponse.status == 200)
    let queries = try #require(JSONSerialization.jsonObject(with: queriesResponse.body) as? [[String: Any]])
    #expect(queries.isEmpty)

    let invalidWindow = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/api/routes?window=all",
        headers: headers
    ))
    #expect(invalidWindow.status == 400)
}

@Test func devKitExposesWindowedHTTPDatabaseLogsAndResourceSafeSources() async throws {
    let router = HTTPRouter()
    let telemetryRuntime = DevKitTelemetryRuntime()
    let telemetry = telemetryRuntime.telemetryStore
    try await router.get("/users/{id}") { request in
        if request.pathParameter("id") == "fails" {
            return .text("private response body", status: 500)
        }
        return .text("ok")
    }

    let sql = "SELECT * FROM accounts WHERE email = 'private@example.com'"
    let fingerprint = await telemetry.fingerprint(forSQL: sql)
    await telemetry.recordDatabaseQuery(fingerprint: fingerprint, durationMilliseconds: 24, failed: false)
    await telemetry.recordDatabaseQuery(fingerprint: fingerprint, durationMilliseconds: 42, failed: true)

    let configuration = DevKitConfiguration(
        enabled: true,
        bearerToken: "local-devkit-token-1234",
        serviceName: "test-api"
    )
    let source = try await telemetryRuntime.install(on: router, configuration: configuration)
    try await PearfyDevKitUI.install(on: router, configuration: configuration, source: source)
    try await router.freeze()

    #expect((await router.handle(try HTTPRequest(
        method: .get,
        target: "/users/private-user?token=private-token"
    ))).status == 200)
    #expect((await router.handle(try HTTPRequest(method: .get, target: "/users/fails"))).status == 500)

    let headers = ["authorization": "Bearer local-devkit-token-1234"]
    let overviewResponse = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/api/overview?window=15m",
        headers: headers
    ))
    let overviewDocument = try #require(JSONSerialization.jsonObject(with: overviewResponse.body) as? [String: Any])
    let overview = try #require(overviewDocument["overview"] as? [String: Any])
    #expect(overview["windowApplied"] as? Bool == true)
    #expect(overview["requestCount"] as? Int == 2)
    #expect(overview["errorCount"] as? Int == 1)
    let sources = try #require(overviewDocument["availableSources"] as? [String])
    #expect(sources.contains("http-window-metrics"))
    #expect(sources.contains("database-query-metrics"))
    #expect(sources.contains("redacted-logs"))
    #expect(sources.contains("process-resources"))
    #expect(Set(sources).count == sources.count)

    let routesResponse = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/api/routes?window=15m",
        headers: headers
    ))
    let routes = try #require(JSONSerialization.jsonObject(with: routesResponse.body) as? [[String: Any]])
    #expect(routes.filter { $0["pathTemplate"] as? String == "/users/{id}" }.count == 1)
    let route = try #require(routes.first { $0["pathTemplate"] as? String == "/users/{id}" })
    let routeMetrics = try #require(route["metrics"] as? [String: Any])
    #expect(routeMetrics["requestCount"] as? Int == 2)
    #expect(routeMetrics["errorCount"] as? Int == 1)

    let queriesResponse = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/api/queries?window=15m",
        headers: headers
    ))
    let queries = try #require(JSONSerialization.jsonObject(with: queriesResponse.body) as? [[String: Any]])
    #expect(queries.count == 1)
    #expect(queries[0]["executionCount"] as? Int == 2)
    #expect(queries[0]["errorCount"] as? Int == 1)

    let logsResponse = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/api/logs?window=15m",
        headers: headers
    ))
    #expect(String(decoding: logsResponse.body, as: UTF8.self).contains("PostgreSQL query failed"))
    #expect(!String(decoding: logsResponse.body, as: UTF8.self).contains("private@example.com"))
    #expect(!String(decoding: logsResponse.body, as: UTF8.self).contains("private-token"))
    #expect(!String(decoding: logsResponse.body, as: UTF8.self).contains("private response body"))

    let instancesResponse = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/api/instances?window=15m",
        headers: headers
    ))
    let instances = try #require(JSONSerialization.jsonObject(with: instancesResponse.body) as? [[String: Any]])
    #expect((instances.first?["memoryBytes"] as? Int ?? 0) > 0)
}

@Test func genericDevKitRuntimePropagatesTraceContextAndCorrelatesQueryLogs() async throws {
    let router = HTTPRouter()
    let runtime = DevKitTelemetryRuntime()
    let statement = "SELECT * FROM accounts WHERE email = 'trace-private@example.com'"
    let fingerprint = await runtime.telemetryStore.fingerprint(forSQL: statement)
    try await router.get("/records/{id}") { _ in
        await runtime.telemetryStore.recordDatabaseQuery(
            fingerprint: fingerprint,
            routeTemplate: TelemetryTaskContext.routeTemplate,
            traceID: TelemetryTaskContext.traceID,
            durationMilliseconds: 23,
            failed: true
        )
        return .text("private database response", status: 500)
    }

    let configuration = DevKitConfiguration(enabled: true, bearerToken: "local-devkit-token-1234")
    let source = try await runtime.install(on: router, configuration: configuration)
    try await PearfyDevKitUI.install(on: router, configuration: configuration, source: source)
    try await router.freeze()

    let traceID = "1af7651916cd43dd8448eb211c80319c"
    let parentSpanID = "00f067aa0ba902b7"
    let response = await router.handle(try HTTPRequest(
        method: .get,
        target: "/records/private-record-id?token=private-query-marker",
        headers: ["traceparent": "00-\(traceID)-\(parentSpanID)-01"]
    ))
    #expect(response.status == 500)
    #expect(response.headers["x-trace-id"] == traceID)
    #expect(response.headers["traceparent"]?.hasPrefix("00-\(traceID)-") == true)

    let headers = ["authorization": "Bearer local-devkit-token-1234"]
    let tracesResponse = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/api/traces?window=15m",
        headers: headers
    ))
    let traces = try #require(JSONSerialization.jsonObject(with: tracesResponse.body) as? [[String: Any]])
    let trace = try #require(traces.first { $0["traceID"] as? String == traceID })
    #expect(trace["kind"] as? String == "request")
    #expect(trace["routeTemplate"] as? String == "/records/{id}")
    #expect((trace["spans"] as? [[String: Any]])?.first?["parentSpanID"] as? String == parentSpanID)

    let queriesResponse = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/api/queries?window=15m",
        headers: headers
    ))
    let queries = try #require(JSONSerialization.jsonObject(with: queriesResponse.body) as? [[String: Any]])
    #expect(queries.count == 1)
    #expect(queries[0]["routeTemplate"] as? String == "/records/{id}")

    let logsResponse = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/api/logs?window=15m",
        headers: headers
    ))
    let logsText = String(decoding: logsResponse.body, as: UTF8.self)
    #expect(logsText.contains(traceID))
    #expect(logsText.contains("PostgreSQL query failed"))
    #expect(!logsText.contains("trace-private@example.com"))
    #expect(!logsText.contains("private-record-id"))
    #expect(!logsText.contains("private-query-marker"))
    #expect(!logsText.contains("private database response"))
}

@Test func devKitCollectsSanitizedRouteTracesAndCorrelatedHTTPErrorsByDefault() async throws {
    let router = HTTPRouter()
    try await router.use { request, next in
        if request.contextValue(HTTPRequest.routeTemplateContextKey) == "/blocked/{id}" {
            return .text("private authorization detail", status: 401)
        }
        return await next(request)
    }
    try await router.get("/users/{id}") { request in
        if request.pathParameter("id") == "explode" {
            return .text("secret exception body", status: 500)
        }
        return HTTPResponse(
            headers: [
                "x-test-trace-id": request.contextValue(HTTPRequest.traceIDContextKey) ?? "",
                "x-test-span-id": request.contextValue(HTTPRequest.spanIDContextKey) ?? ""
            ],
            body: Data("ok".utf8)
        )
    }
    try await router.get("/blocked/{id}") { _ in .text("unreachable") }
    try await PearfyDevKitUI.install(
        on: router,
        configuration: DevKitConfiguration(enabled: true, bearerToken: "local-devkit-token-1234", instanceID: "api-local")
    )
    try await router.freeze()

    let successful = await router.handle(try HTTPRequest(
        method: .get,
        target: "/users/concrete-secret-id?token=query-secret",
        headers: ["x-private": "header-secret"],
        body: Data("request-secret".utf8)
    ))
    let serverError = await router.handle(try HTTPRequest(method: .get, target: "/users/explode"))
    let notFound = await router.handle(try HTTPRequest(method: .get, target: "/missing/concrete-secret?token=query-secret"))
    let middlewareError = await router.handle(try HTTPRequest(method: .get, target: "/blocked/user-1"))
    #expect(successful.status == 200)
    #expect(successful.headers["x-test-trace-id"]?.count == 32)
    #expect(successful.headers["x-test-span-id"]?.count == 16)
    #expect(serverError.status == 500)
    #expect(notFound.status == 404)
    #expect(middlewareError.status == 401)
    let missingDevKitRoute = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/api/missing?token=dashboard-secret"
    ))
    #expect(missingDevKitRoute.status == 404)

    let headers = ["authorization": "Bearer local-devkit-token-1234"]
    let tracesResponse = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/api/traces?window=1h",
        headers: headers
    ))
    #expect(tracesResponse.status == 200)
    let traces = try #require(JSONSerialization.jsonObject(with: tracesResponse.body) as? [[String: Any]])
    #expect(traces.count == 4)
    #expect(tracesResponse.body.range(of: Data("concrete-secret-id".utf8)) == nil)
    #expect(tracesResponse.body.range(of: Data("query-secret".utf8)) == nil)
    #expect(tracesResponse.body.range(of: Data("header-secret".utf8)) == nil)
    #expect(tracesResponse.body.range(of: Data("request-secret".utf8)) == nil)
    #expect(tracesResponse.body.range(of: Data("secret exception body".utf8)) == nil)
    #expect(tracesResponse.body.range(of: Data("dashboard-secret".utf8)) == nil)
    let userTrace = try #require(traces.first { $0["routeTemplate"] as? String == "/users/{id}" })
    #expect(userTrace["statusCode"] as? Int == 200 || userTrace["statusCode"] as? Int == 500)
    #expect((userTrace["spans"] as? [[String: Any]])?.count == 1)

    let errorsResponse = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/api/errors?window=1h",
        headers: headers
    ))
    #expect(errorsResponse.status == 200)
    let errors = try #require(JSONSerialization.jsonObject(with: errorsResponse.body) as? [[String: Any]])
    #expect(Set(errors.compactMap { $0["statusCode"] as? Int }) == [401, 404, 500])
    #expect(errors.allSatisfy { $0["traceID"] is String && $0["durationMilliseconds"] is NSNumber })

    let routeResponse = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/api/routes?window=1h",
        headers: headers
    ))
    let routeList = try #require(JSONSerialization.jsonObject(with: routeResponse.body) as? [[String: Any]])
    let usersRoute = try #require(routeList.first { $0["pathTemplate"] as? String == "/users/{id}" })
    let metrics = try #require(usersRoute["metrics"] as? [String: Any])
    #expect(metrics["requestCount"] as? Int == 2)
    #expect(metrics["errorCount"] as? Int == 1)
}

@Test func devKitRejectsEnabledConfigurationWithoutStrongToken() async throws {
    let router = HTTPRouter()
    var rejected = false
    do {
        try await PearfyDevKitUI.install(
            on: router,
            configuration: DevKitConfiguration(enabled: true, environment: .production)
        )
    } catch DevKitConfigurationError.invalidToken {
        rejected = true
    }
    #expect(rejected)
    #expect(try await router.contractOperations().isEmpty)
}

@Test func devKitDashboardAssetsSetRestrictiveHeadersAndProviderErrorsAreRedacted() async throws {
    let router = HTTPRouter()
    let source = DevKitSnapshotSource { _ in
        throw NSError(domain: "private diagnostic", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret-value"])
    }
    try await PearfyDevKitUI.install(
        on: router,
        configuration: DevKitConfiguration(enabled: true, bearerToken: "local-devkit-token-1234"),
        source: source
    )
    try await router.freeze()

    let page = await router.handle(try HTTPRequest(method: .get, target: "/__pearfy/devkit"))
    #expect(page.status == 200)
    #expect(page.headers["content-security-policy"]?.contains("default-src 'self'") == true)
    #expect(!String(decoding: page.body, as: UTF8.self).contains("DEMO"))
    #expect(String(decoding: page.body, as: UTF8.self).contains("id=\"show-empty-routes\""))
    #expect(String(decoding: page.body, as: UTF8.self).contains("id=\"input-traces\""))
    #expect(String(decoding: page.body, as: UTF8.self).contains("id=\"work-traces\""))

    let dashboardScript = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/assets/devkit.js"
    ))
    let script = String(decoding: dashboardScript.body, as: UTF8.self)
    #expect(dashboardScript.status == 200)
    #expect(script.contains("localStorage.setItem(tokenStorageKey, value)"))
    #expect(script.contains("token = loadToken()"))
    #expect(script.contains("removeStoredToken()"))
    #expect(script.contains("showEmptyRoutes || hasTraffic"))
    #expect(script.contains("if (empty) {"))
    #expect(script.contains("showEmptyRoutesToggle?.addEventListener"))
    #expect(script.contains("trace.kind === 'work'"))
    #expect(script.contains("paintTraceList('input-traces-content'"))
    #expect(script.contains("paintTraceList('work-traces-content'"))
    #expect(script.contains("if (refreshInProgress) return false;"))
    #expect(script.contains("}, 10_000);"))

    let tracesCSS = await router.handle(try HTTPRequest(method: .get, target: "/__pearfy/devkit/assets/traces.css"))
    #expect(tracesCSS.status == 200)
    #expect(String(decoding: tracesCSS.body, as: UTF8.self).contains(".trace-card"))

    let response = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/api/overview",
        headers: ["authorization": "Bearer local-devkit-token-1234"]
    ))
    #expect(response.status == 503)
    #expect(!String(decoding: response.body, as: UTF8.self).contains("secret-value"))

    let traces = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/api/traces",
        headers: ["authorization": "Bearer local-devkit-token-1234"]
    ))
    #expect(traces.status == 200)
}

@Test func devKitReturnsWorkTracesInTheirOwnClassification() async throws {
    let router = HTTPRouter()
    let workTrace = DevKitTrace(
        traceID: "work-trace-0000000000000000000000000000",
        kind: .work,
        routeTemplate: "/jobs/{jobID}",
        startedAt: Date(),
        durationMilliseconds: 18,
        status: "ok",
        spans: [DevKitSpan(
            spanID: "work-span-000000",
            name: "catalog.reindex",
            startedAt: Date(),
            durationMilliseconds: 18,
            status: "ok"
        )]
    )
    let source = DevKitSnapshotSource { query in
        DevKitSnapshot(
            overview: DevKitOverview(
                requestedWindow: query.window,
                windowApplied: true,
                scope: "test"
            ),
            traces: [workTrace]
        )
    }
    try await PearfyDevKitUI.install(
        on: router,
        configuration: DevKitConfiguration(enabled: true, bearerToken: "local-devkit-token-1234"),
        source: source
    )
    try await router.freeze()

    let response = await router.handle(try HTTPRequest(
        method: .get,
        target: "/__pearfy/devkit/api/traces",
        headers: ["authorization": "Bearer local-devkit-token-1234"]
    ))
    #expect(response.status == 200)
    let traces = try #require(JSONSerialization.jsonObject(with: response.body) as? [[String: Any]])
    let trace = try #require(traces.first { $0["traceID"] as? String == workTrace.traceID })
    #expect(trace["kind"] as? String == "work")
    #expect(trace["routeTemplate"] as? String == "/jobs/{jobID}")
}

@Test func devKitRuntimeServesRecordedBackgroundWorkTraces() async throws {
    let router = HTTPRouter()
    let runtime = DevKitTelemetryRuntime()
    let configuration = DevKitConfiguration(
        enabled: true,
        bearerToken: "local-devkit-token-1234",
        serviceName: "test-api"
    )
    let source = try await runtime.install(on: router, configuration: configuration)
    try await PearfyDevKitUI.install(on: router, configuration: configuration, source: source)
    try await router.freeze()

    let scheduler = JobScheduler(onExecution: { execution in
        await runtime.workTraceRecorder.record(
            name: execution.name,
            startedAt: execution.startedAt,
            durationMilliseconds: execution.durationMilliseconds,
            status: execution.status == .succeeded ? .ok : .error
        )
    })
    try await scheduler.schedule("news-sync", every: .seconds(30), runImmediately: true) {}
    try await scheduler.start()

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    var responseStatus = 0
    var traces: [[String: Any]] = []
    while clock.now < deadline {
        let response = await router.handle(try HTTPRequest(
            method: .get,
            target: "/__pearfy/devkit/api/traces?window=15m",
            headers: ["authorization": "Bearer local-devkit-token-1234"]
        ))
        responseStatus = response.status
        traces = (try? JSONSerialization.jsonObject(with: response.body)) as? [[String: Any]] ?? []
        if traces.contains(where: { $0["kind"] as? String == "work" }) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    try await scheduler.stop()

    #expect(responseStatus == 200)
    let trace = try #require(traces.first { $0["kind"] as? String == "work" })
    #expect(trace["method"] == nil)
    #expect(trace["routeTemplate"] == nil)
    #expect(trace["status"] as? String == "ok")
    #expect((trace["spans"] as? [[String: Any]])?.first?["name"] as? String == "work news-sync")
}

@Test func devKitDecodesLegacyTracesWithoutKind() throws {
    let requestData = Data(#"{"traceID":"request-trace","routeTemplate":"/users/{id}","method":"GET","startedAt":"2026-09-28T12:00:00Z","durationMilliseconds":12,"status":"ok"}"#.utf8)
    let workData = Data(#"{"traceID":"work-trace","startedAt":"2026-09-28T12:00:00Z","durationMilliseconds":18,"status":"ok"}"#.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    #expect(try decoder.decode(DevKitTrace.self, from: requestData).kind == .request)
    #expect(try decoder.decode(DevKitTrace.self, from: workData).kind == .work)
}

@Test func processResourceSamplerReportsCurrentResidentMemoryAndCPUInterval() async throws {
    let sampler = DevKitProcessResourceSampler()
    await sampler.start()
    try await Task.sleep(for: .milliseconds(1_100))
    let sample = try #require(await sampler.latestSample())
    #expect(sample.residentMemoryBytes.map { $0 > 0 } == true)
    #expect(sample.cpuPercent.map { $0.isFinite && $0 >= 0 } == true)
}

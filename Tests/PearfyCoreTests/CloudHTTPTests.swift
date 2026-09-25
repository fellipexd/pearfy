import Foundation
import PearfyCloud
import PearfyObservability
import Testing

@Test func circuitBreakerOpensAndAllowsOneSuccessfulProbe() async throws {
    let breaker = CircuitBreaker(failureThreshold: 1, resetAfter: .milliseconds(10))
    try await breaker.acquire()
    await breaker.record(success: false)

    var rejectedWhileOpen = false
    do {
        try await breaker.acquire()
    } catch CloudHTTPError.circuitOpen {
        rejectedWhileOpen = true
    }
    #expect(rejectedWhileOpen)

    try await Task.sleep(for: .milliseconds(15))
    try await breaker.acquire()
    await breaker.record(success: true)
    try await breaker.acquire()
}

@Test func retryPolicyBoundsAttemptsAndExponentialBackoff() {
    let policy = HTTPRetryPolicy(maximumAttempts: 0, initialBackoffMilliseconds: 25, maximumBackoffMilliseconds: 80)
    #expect(policy.maximumAttempts == 1)
    #expect(policy.initialBackoffMilliseconds == 25)
    #expect(policy.maximumBackoffMilliseconds == 80)
}

@Test func outboundHTTPBoundsConcurrentAndQueuedRequests() async throws {
    let transport = SlowHTTPTransport()
    let metrics = MetricsRegistry()
    let client = CloudHTTPClient(
        transport: transport,
        retryPolicy: HTTPRetryPolicy(maximumAttempts: 1),
        maximumConcurrentRequests: 1,
        maximumQueuedRequests: 1,
        metrics: metrics
    )
    let request = URLRequest(url: URL(string: "https://example.test/health")!)
    let first = Task { try await client.send(request) }
    for _ in 0..<100 {
        if await transport.startedCount() == 1 { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await transport.startedCount() == 1)

    let second = Task { try await client.send(request) }
    for _ in 0..<100 {
        if await client.requestCounts().queued == 1 { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await client.requestCounts().queued == 1)
    for _ in 0..<100 {
        if await metrics.prometheusText().contains("pearfy_outbound_http_queue_depth{client=\"default\"} 1.0") { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    let metricsWhileQueued = await metrics.prometheusText()
    #expect(metricsWhileQueued.contains("pearfy_outbound_http_requests_in_flight{client=\"default\"} 1.0"))
    #expect(metricsWhileQueued.contains("pearfy_outbound_http_queue_depth{client=\"default\"} 1.0"))

    var overloadRejected = false
    do {
        _ = try await client.send(request)
    } catch CloudHTTPError.overloaded {
        overloadRejected = true
    }
    #expect(overloadRejected)
    #expect(try await first.value.statusCode == 200)
    #expect(try await second.value.statusCode == 200)
    let counts = await client.requestCounts()
    let maximumConcurrent = await transport.maximumConcurrent
    let metricsAfter = await metrics.prometheusText()
    #expect(counts.active == 0)
    #expect(counts.queued == 0)
    #expect(maximumConcurrent == 1)
    #expect(metricsAfter.contains("pearfy_outbound_http_requests_in_flight{client=\"default\"} 0.0"))
    #expect(metricsAfter.contains("pearfy_outbound_http_queue_depth{client=\"default\"} 0.0"))
}

@Test func cancellingQueuedOutboundRequestReleasesItsQueueSlot() async throws {
    let transport = SlowHTTPTransport(delay: .milliseconds(80))
    let metrics = MetricsRegistry()
    let client = CloudHTTPClient(
        transport: transport,
        retryPolicy: HTTPRetryPolicy(maximumAttempts: 1),
        maximumConcurrentRequests: 1,
        maximumQueuedRequests: 1,
        metrics: metrics
    )
    let request = URLRequest(url: URL(string: "https://example.test/health")!)
    let first = Task { try await client.send(request) }
    for _ in 0..<100 {
        if await transport.startedCount() == 1 { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    let queued = Task { try await client.send(request) }
    for _ in 0..<100 {
        if await client.requestCounts().queued == 1 { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await client.requestCounts().queued == 1)

    queued.cancel()
    var cancellationPreserved = false
    do {
        _ = try await queued.value
    } catch is CancellationError {
        cancellationPreserved = true
    }
    #expect(cancellationPreserved)
    #expect(await client.requestCounts().queued == 0)

    let next = Task { try await client.send(request) }
    #expect(try await first.value.statusCode == 200)
    #expect(try await next.value.statusCode == 200)
    let counts = await client.requestCounts()
    let metricsAfter = await metrics.prometheusText()
    #expect(counts.active == 0)
    #expect(counts.queued == 0)
    #expect(metricsAfter.contains("pearfy_outbound_http_requests_in_flight{client=\"default\"} 0.0"))
    #expect(metricsAfter.contains("pearfy_outbound_http_queue_depth{client=\"default\"} 0.0"))
}

private actor SlowHTTPTransport: CloudHTTPTransport {
    let delay: Duration
    private var active = 0
    private var maximum = 0
    private var started = 0

    var maximumConcurrent: Int { maximum }

    init(delay: Duration = .milliseconds(30)) { self.delay = delay }

    func startedCount() -> Int { started }

    func send(_ request: URLRequest) async throws -> CloudHTTPResponse {
        started += 1
        active += 1
        maximum = max(maximum, active)
        do {
            try await Task.sleep(for: delay)
        } catch {
            active -= 1
            throw error
        }
        active -= 1
        return CloudHTTPResponse(statusCode: 200)
    }
}

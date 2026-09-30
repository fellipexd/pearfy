import Foundation
import PearfyGatewayLab
import Testing

@Test func gatewayLabRejectsFakeInProductionAndLiveEndpointFallback() throws {
    let production = GatewayLabConfiguration(environment: .production, mode: .fake)
    #expect(throws: GatewayLabError.fakeForbiddenInProduction) { try production.validate() }

    let liveEndpoint = GatewayLabConfiguration(
        environment: .development,
        mode: .fake,
        endpoint: URL(string: "https://api.payments.example")
    )
    #expect(throws: GatewayLabError.liveEndpointInFakeMode) { try liveEndpoint.validate() }
}

@Test func gatewayLabRejectsMalformedAndCredentialBearingEndpoints() throws {
    let fileEndpoint = GatewayLabConfiguration(
        environment: .development,
        mode: .fake,
        endpoint: URL(fileURLWithPath: "/tmp/provider")
    )
    #expect(throws: GatewayLabError.invalidEndpoint) { try fileEndpoint.validate() }

    let credentialEndpoint = GatewayLabConfiguration(
        environment: .development,
        mode: .fake,
        endpoint: URL(string: "https://user:secret@localhost/provider")
    )
    #expect(throws: GatewayLabError.invalidEndpoint) { try credentialEndpoint.validate() }

    let localEndpoint = GatewayLabConfiguration(
        environment: .development,
        mode: .fake,
        endpoint: URL(string: "http://127.0.0.2/provider")
    )
    try localEndpoint.validate()
}

@Test func fakeHTTPSequencesAreIsolatedByRunAndJournalOmitsSensitiveRequestData() async throws {
    let first = try FakeHTTPResponse(status: 202, body: Data("first".utf8))
    let second = try FakeHTTPResponse(status: 200, body: Data("second".utf8))
    let fixture = try FakeHTTPFixture(
        method: "POST",
        host: "payments.test",
        path: "/charge",
        responses: [first, second],
        delay: .seconds(2)
    )
    let provider = try FakeHTTPProvider(fixtures: [fixture])
    let clockA = GatewayLabVirtualClock()
    let runA = try GatewayLabContext(runID: "a", tenantID: "tenant", seed: 42, clock: clockA)
    let runB = try GatewayLabContext(runID: "b", tenantID: "tenant", seed: 42)
    let request = FakeHTTPRequest(
        method: "post",
        url: try #require(URL(string: "https://payments.test/charge?secret=query")),
        headers: ["Authorization": "Bearer private"],
        body: Data("private body".utf8)
    )

    #expect(try await provider.send(request, context: runA) == first)
    #expect(try await provider.send(request, context: runA) == second)
    #expect(try await provider.send(request, context: runB) == first)
    #expect(await clockA.now() == .seconds(4))
    let entries = await provider.journalEntries()
    #expect(entries.count == 3)
    #expect(entries.allSatisfy { $0.path == "/charge" })
    #expect(!String(describing: entries).contains("private"))
    #expect(!String(describing: entries).contains("secret"))
}

@Test func fakeHTTPUnmatchedRequestsFailClosed() async throws {
    let response = try FakeHTTPResponse()
    let fixture = try FakeHTTPFixture(method: "GET", host: "service.test", path: "/known", responses: [response])
    let provider = try FakeHTTPProvider(fixtures: [fixture])
    let context = try GatewayLabContext(runID: "run")
    let request = FakeHTTPRequest(method: "GET", url: try #require(URL(string: "https://service.test/unknown")))
    do {
        _ = try await provider.send(request, context: context)
        Issue.record("unmatched request should fail without a live fallback")
    } catch {
        #expect(error as? GatewayLabError == .noMatchingFixture)
    }
    let entry = try #require(await provider.journalEntries().first)
    #expect(entry.path == "<unmatched>")
}

@Test func fakeHTTPRunAndJournalRetentionAreBoundedAndResetReleasesCapacity() async throws {
    let response = try FakeHTTPResponse(status: 204)
    let fixture = try FakeHTTPFixture(method: "GET", host: "service.test", path: "/known", responses: [response])
    let provider = try FakeHTTPProvider(fixtures: [fixture], maximumTrackedRuns: 1, maximumJournalEntries: 2)
    let request = FakeHTTPRequest(method: "GET", url: try #require(URL(string: "https://service.test/known")))
    let runA = try GatewayLabContext(runID: "a")
    let runB = try GatewayLabContext(runID: "b")

    #expect(try await provider.send(request, context: runA) == response)
    do {
        _ = try await provider.send(request, context: runB)
        Issue.record("a second tracked run must be rejected at capacity")
    } catch {
        #expect(error as? GatewayLabError == .resourceLimitExceeded)
    }

    await provider.reset(runID: "a")
    #expect(try await provider.send(request, context: runB) == response)
    let journal = await provider.journalEntries()
    #expect(journal.count == 2)
    #expect(journal.map(\.outcome) == ["capacity-exceeded", "response"])
}

@Test func fakeHTTPRejectsOversizedFixturesAndAmbiguousRoutes() throws {
    let response = try FakeHTTPResponse()
    let tooManyResponses = Array(repeating: response, count: GatewayLabLimits.maximumResponsesPerFixture + 1)
    #expect(throws: GatewayLabError.invalidFixture) {
        try FakeHTTPFixture(method: "GET", host: "service.test", path: "/known", responses: tooManyResponses)
    }

    let fixture = try FakeHTTPFixture(method: "GET", host: "service.test", path: "/known", responses: [response])
    #expect(throws: GatewayLabError.invalidFixture) {
        try FakeHTTPProvider(fixtures: [fixture, fixture])
    }
    #expect(throws: GatewayLabError.invalidFixture) {
        try FakeHTTPProvider(fixtures: [fixture], maximumJournalEntries: GatewayLabLimits.maximumJournalEntries + 1)
    }

    let maximumBody = try FakeHTTPResponse(body: Data(repeating: 0, count: GatewayLabLimits.maximumResponseBodyBytes))
    let oversizedScenario = try FakeHTTPFixture(
        method: "GET",
        host: "service.test",
        path: "/large",
        responses: Array(repeating: maximumBody, count: GatewayLabLimits.maximumTotalResponseBodyBytes / GatewayLabLimits.maximumResponseBodyBytes + 1)
    )
    #expect(throws: GatewayLabError.invalidFixture) {
        try FakeHTTPProvider(fixtures: [oversizedScenario])
    }
    #expect(throws: GatewayLabError.invalidFixture) {
        try FakeHTTPFixture(method: "GET", host: "service.test:443", path: "/known", responses: [response])
    }
}

@Test func timeoutBeforeProcessingCanRetryWithoutConsumingTheResponseSequence() async throws {
    let first = try FakeHTTPResponse(status: 201, body: Data("first".utf8))
    let second = try FakeHTTPResponse(status: 200, body: Data("second".utf8))
    let fixture = try FakeHTTPFixture(
        method: "POST",
        host: "service.test",
        path: "/operation",
        responses: [first, second],
        faults: [.timeoutBeforeProcessing]
    )
    let provider = try FakeHTTPProvider(fixtures: [fixture])
    let context = try GatewayLabContext(runID: "retry")
    let request = FakeHTTPRequest(method: "POST", url: try #require(URL(string: "https://service.test/operation")))

    do {
        _ = try await provider.send(request, context: context)
        Issue.record("the configured timeout should be raised")
    } catch {
        #expect(error as? GatewayLabError == .timeout)
    }
    #expect(try await provider.send(request, context: context) == first)
    #expect(try await provider.send(request, context: context) == second)
}

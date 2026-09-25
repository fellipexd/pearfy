import Foundation
import PearfyNIO
import PearfyMacros
import PearfySecurity
import PearfyValidation
import PearfyWeb
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Test func routerPrefersStaticPathOverParameterAndSupportsHead() async throws {
    let router = HTTPRouter()
    try await router.get("/{value}") { request in
        .text("dynamic:\(request.pathParameter("value") ?? "missing")")
    }
    try await router.get("/health") { _ in .text("ok") }
    try await router.freeze()

    let staticResponse = await router.handle(try HTTPRequest(method: .get, target: "/health"))
    let dynamicResponse = await router.handle(try HTTPRequest(method: .get, target: "/hello"))
    let headResponse = await router.handle(try HTTPRequest(method: .head, target: "/health"))

    #expect(staticResponse.status == 200)
    #expect(String(decoding: staticResponse.body, as: UTF8.self) == "ok")
    #expect(String(decoding: dynamicResponse.body, as: UTF8.self) == "dynamic:hello")
    #expect(headResponse.status == 200)
    #expect(headResponse.body.isEmpty)
}

@Test func routerReturnsDeterministicNotFoundAndMethodNotAllowedResponses() async throws {
    let router = HTTPRouter()
    try await router.get("/items/{id}") { _ in .text("item") }
    try await router.freeze()

    let missing = await router.handle(try HTTPRequest(method: .get, target: "/other"))
    let wrongMethod = await router.handle(try HTTPRequest(method: .post, target: "/items/5"))
    #expect(missing.status == 404)
    #expect(wrongMethod.status == 405)
    #expect(wrongMethod.headers["allow"] == "GET, HEAD")
}

@Test func routerEnforcesBodyAndHeaderLimits() async throws {
    let router = HTTPRouter(maximumBodyBytes: 4, maximumHeaderBytes: 12)
    try await router.post("/echo") { request in .text(String(decoding: request.body, as: UTF8.self)) }
    try await router.freeze()

    let bodyTooLarge = await router.handle(try HTTPRequest(
        method: .post,
        target: "/echo",
        body: Data("12345".utf8)
    ))
    let headersTooLarge = await router.handle(try HTTPRequest(
        method: .post,
        target: "/echo",
        headers: ["long-header": "value"]
    ))
    #expect(bodyTooLarge.status == 413)
    #expect(headersTooLarge.status == 431)
}

@Test func middlewareCanAddRequestCorrelationHeader() async throws {
    let router = HTTPRouter()
    try await router.use(HTTPRouter.requestID())
    try await router.get("/hello") { request in
        .text(request.headers["x-request-id"] ?? "missing")
    }
    try await router.freeze()

    let response = await router.handle(try HTTPRequest(method: .get, target: "/hello"))
    let requestID = response.headers["x-request-id"]
    #expect(response.status == 200)
    #expect(requestID != nil)
    #expect(String(decoding: response.body, as: UTF8.self) == requestID)
}

@Test func routerAdmissionLimitRejectsExcessInFlightRequests() async throws {
    let router = HTTPRouter(maximumInFlightRequests: 2)
    try await router.get("/slow") { _ in
        try await Task.sleep(for: .milliseconds(25))
        return .text("done")
    }
    try await router.freeze()

    let statuses = try await withThrowingTaskGroup(of: Int.self) { group in
        for _ in 0..<5 {
            group.addTask {
                await router.handle(try HTTPRequest(method: .get, target: "/slow")).status
            }
        }
        var values: [Int] = []
        for try await value in group { values.append(value) }
        return values
    }
    #expect(statuses.filter { $0 == 200 }.count == 2)
    #expect(statuses.filter { $0 == 503 }.count == 3)
    #expect(await router.currentInFlightRequests() == 0)
}

@Test func routerDeadlineCancelsCooperativeHandler() async throws {
    let router = HTTPRouter(requestDeadline: .milliseconds(5))
    try await router.get("/slow") { _ in
        try await Task.sleep(for: .seconds(1))
        return .text("too late")
    }
    try await router.freeze()

    let response = await router.handle(try HTTPRequest(method: .get, target: "/slow"))
    #expect(response.status == 504)
    #expect(await router.currentInFlightRequests() == 0)
}

@Test func routerRejectsRegistrationAfterFreezeAndDuplicatePatterns() async throws {
    let router = HTTPRouter()
    try await router.get("/users/{id}") { _ in .text("first") }
    var duplicateRejected = false
    do {
        try await router.get("/users/{userID}") { _ in .text("second") }
    } catch HTTPError.duplicateRoute {
        duplicateRejected = true
    }
    #expect(duplicateRejected)

    try await router.freeze()
    var frozenRejected = false
    do {
        try await router.get("/late") { _ in .text("late") }
    } catch HTTPError.routerFrozen {
        frozenRejected = true
    }
    #expect(frozenRejected)
}

@Test func routerExportsOpenAPIDocumentWithPathParameters() async throws {
    let router = HTTPRouter()
    try await router.get("/users/{id}") { _ in .text("user") }
    try await router.freeze()

    let data = try await router.openAPIDocument(title: "Accounts", version: "v1")
    let document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let paths = try #require(document["paths"] as? [String: Any])
    let pathItem = try #require(paths["/users/{id}"] as? [String: Any])
    let get = try #require(pathItem["get"] as? [String: Any])
    let parameters = try #require(get["parameters"] as? [[String: Any]])
    #expect(parameters.first?["name"] as? String == "id")
    #expect(parameters.first?["required"] as? Bool == true)
}

@Test func restControllerMacrosGenerateBoundRoutes() async throws {
    let router = HTTPRouter()
    try await MacroGreetingController.__pearfy_registerRoutes(in: router, instance: MacroGreetingController())
    try await router.freeze()

    let pathResponse = await router.handle(try HTTPRequest(method: .get, target: "/api/hello/pear"))
    let queryResponse = await router.handle(try HTTPRequest(method: .get, target: "/api/search?q=swift"))
    let bodyResponse = await router.handle(try HTTPRequest(
        method: .post,
        target: "/api/echo",
        body: Data("{\"value\":\"json\"}".utf8)
    ))
    let invalidBodyResponse = await router.handle(try HTTPRequest(
        method: .post,
        target: "/api/users",
        body: Data("{\"name\":\"  \",\"age\":0}".utf8)
    ))
    let validBodyResponse = await router.handle(try HTTPRequest(
        method: .post,
        target: "/api/users",
        body: Data("{\"name\":\"Pear\",\"age\":3}".utf8)
    ))
    let statusResponse = await router.handle(try HTTPRequest(method: .get, target: "/api/created"))

    #expect(String(decoding: pathResponse.body, as: UTF8.self) == "hello pear")
    #expect(String(decoding: queryResponse.body, as: UTF8.self) == "query swift")
    #expect(String(decoding: bodyResponse.body, as: UTF8.self) == "body json")
    #expect(invalidBodyResponse.status == 400)
    let violations = try JSONDecoder().decode([ValidationViolation].self, from: invalidBodyResponse.body)
    #expect(violations.first?.field == "name")
    #expect(violations.contains { $0.field == "age" })
    #expect(validBodyResponse.status == HTTPStatus.created.rawValue)
    #expect(String(decoding: validBodyResponse.body, as: UTF8.self) == "created Pear")
    #expect(statusResponse.status == HTTPStatus.created.rawValue)
}

@Test func controllerSecurityMacrosApplyAuthenticatedRolesAndPermitAll() async throws {
    let router = HTTPRouter()
    try await router.use { request, next in
        guard request.headers["x-test-auth"] == "yes" else { return await next(request) }
        return await next(
            request
                .addingContextValue(HTTPRequest.authenticatedContextKey, value: "true")
                .addingContextValue(HTTPRequest.rolesContextKey, value: request.headers["x-test-role"] ?? "")
        )
    }
    try await router.use(SecurityMiddleware.denyByDefault())
    try await MacroSecurityController.__pearfy_registerRoutes(in: router, instance: MacroSecurityController())
    try await router.freeze()

    let anonymous = await router.handle(try HTTPRequest(method: .get, target: "/secure/admin"))
    let forbidden = await router.handle(try HTTPRequest(
        method: .get,
        target: "/secure/admin",
        headers: ["x-test-auth": "yes", "x-test-role": "USER"]
    ))
    let allowed = await router.handle(try HTTPRequest(
        method: .get,
        target: "/secure/admin",
        headers: ["x-test-auth": "yes", "x-test-role": "ADMIN"]
    ))
    let publicResponse = await router.handle(try HTTPRequest(method: .get, target: "/secure/public"))

    #expect(anonymous.status == 401)
    #expect(forbidden.status == 403)
    #expect(allowed.status == 200)
    #expect(publicResponse.status == 200)
}

@Test func requestParsesRepeatedQueryAndRejectsTraversalSegments() throws {
    let request = try HTTPRequest(method: .get, target: "/search?q=pear&q=swift")
    #expect(request.query["q"] == ["pear", "swift"])

    var rejected = false
    do {
        _ = try HTTPRequest(method: .get, target: "/files/%2e%2e/secret")
    } catch HTTPError.badRequest {
        rejected = true
    }
    #expect(rejected)
}

@Test func nioListenerServesRequestsAndShutsDown() async throws {
    let router = HTTPRouter()
    try await router.get("/hello/{name}") { request in
        .text("Hello, \(request.pathParameter("name") ?? "unknown")!")
    }
    try await router.post("/echo") { request in .text(String(decoding: request.body, as: UTF8.self)) }
    let server = PearfyHTTPServer(router: router, port: 0, maximumBodyBytes: 4)
    try await server.start()
    guard let port = await server.boundPort() else {
        try await server.stop()
        Issue.record("NIO did not expose its ephemeral bound port")
        return
    }

    let baseURL = try #require(URL(string: "http://127.0.0.1:\(port)"))
    let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("hello/pear"))
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self) == "Hello, pear!")

    var oversizedRequest = URLRequest(url: baseURL.appendingPathComponent("echo"))
    oversizedRequest.httpMethod = "POST"
    oversizedRequest.httpBody = Data("too-large".utf8)
    let (_, oversizedResponse) = try await URLSession.shared.data(for: oversizedRequest)
    #expect((oversizedResponse as? HTTPURLResponse)?.statusCode == 413)
    try await server.stop()
}

@Test func disconnectedClientReleasesAdmissionSlotAfterRequestDeadline() async throws {
    let router = HTTPRouter(maximumInFlightRequests: 1, requestDeadline: .milliseconds(40))
    try await router.get("/slow") { _ in
        try await Task.sleep(for: .seconds(2))
        return .text("late")
    }
    try await router.get("/fast") { _ in .text("ready") }
    let server = PearfyHTTPServer(router: router, port: 0)
    try await server.start()
    guard let port = await server.boundPort(), let slowURL = URL(string: "http://127.0.0.1:\(port)/slow") else {
        try await server.stop()
        Issue.record("NIO did not expose an ephemeral bound port")
        return
    }

    let client = Task {
        _ = try? await URLSession.shared.data(from: slowURL)
    }
    for _ in 0..<100 {
        if await router.currentInFlightRequests() == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await router.currentInFlightRequests() == 1)
    client.cancel()
    await client.value

    for _ in 0..<100 {
        if await router.currentInFlightRequests() == 0 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await router.currentInFlightRequests() == 0)

    let fastURL = try #require(URL(string: "http://127.0.0.1:\(port)/fast"))
    let (data, response) = try await URLSession.shared.data(from: fastURL)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self) == "ready")
    try await server.stop()
}

@Test func nioShutdownWaitsForActiveHandlersToUnwind() async throws {
    let concurrency = 8
    let router = HTTPRouter(maximumInFlightRequests: concurrency, requestDeadline: .seconds(1))
    try await router.get("/work") { _ in
        try await Task.sleep(for: .milliseconds(80))
        return .text("complete")
    }
    let server = PearfyHTTPServer(router: router, port: 0)
    try await server.start()
    guard let port = await server.boundPort(), let url = URL(string: "http://127.0.0.1:\(port)/work") else {
        try await server.stop()
        Issue.record("NIO did not expose an ephemeral bound port")
        return
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpMaximumConnectionsPerHost = concurrency
    let session = URLSession(configuration: configuration)
    let clients = (0..<concurrency).map { _ in
        Task {
            _ = try? await session.data(from: url)
        }
    }
    for _ in 0..<100 {
        if await router.currentInFlightRequests() == concurrency { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await router.currentInFlightRequests() == concurrency)

    try await server.stop()
    for client in clients { await client.value }
    session.invalidateAndCancel()
    #expect(await router.currentInFlightRequests() == 0)
}

@RestController("/api")
@PermitAll
private struct MacroGreetingController: Sendable {
    @Get("/hello/{name}")
    func greet(@PathVariable name: String) -> String {
        "hello \(name)"
    }

    @Get("/search")
    func search(@QueryParam(name: "q") term: String) -> String {
        "query \(term)"
    }

    @Post("/echo")
    func echo(@RequestBody payload: MacroGreetingPayload) -> String {
        "body \(payload.value)"
    }

    @Post("/users")
    @ResponseStatus(.created)
    func create(@Valid user: MacroUserInput) -> String {
        "created \(user.name)"
    }

    @Get("/created")
    @ResponseStatus(.created)
    func created() -> String {
        "created"
    }
}

private struct MacroGreetingPayload: Codable, Sendable {
    let value: String
}

@Validated
private struct MacroUserInput: Codable, Validatable {
    @NotBlank
    @Size(min: 2, max: 20)
    let name: String
    @Min(1)
    @Max(10)
    let age: Int

}

@RestController("/secure")
@PermitAll
private struct MacroSecurityController: Sendable {
    @Get("/admin")
    @RolesAllowed("ADMIN")
    func admin() -> String { "admin" }

    @Get("/signed-in")
    @Authenticated
    func signedIn() -> String { "signed in" }

    @Get("/public")
    @PermitAll
    func publicRoute() -> String { "public" }
}

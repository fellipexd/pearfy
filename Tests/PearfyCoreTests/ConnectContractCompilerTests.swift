import PearfyConnect
import PearfyMacros
import PearfyWeb
import Testing

@Test func connectCompilerBuildsDeterministicGroupFilteredRouteSnapshot() async throws {
    let router = HTTPRouter()
    try await MobileContractController.__pearfy_registerRoutes(in: router, instance: MobileContractController())
    try await InternalContractController.__pearfy_registerRoutes(in: router, instance: InternalContractController())
    try await router.get("/unpublished") { _ in .text("private") }
    try await router.freeze()

    let compiler = PearfyConnectCompiler()
    let first = try await compiler.compile(router: router, buildRevision: "test-revision")
    let second = try await compiler.compile(router: router, buildRevision: "test-revision")
    #expect(try first.canonicalJSON() == second.canonicalJSON())
    #expect(try first.schemaHash() == second.schemaHash())
    #expect(first.canGenerateSDKs == false)
    #expect(first.schemaCoverage == .routesAndPoliciesOnly)
    #expect(first.groups.map(\.name) == ["mobile"])
    #expect(first.operations.count == 1)

    let operation = try #require(first.operations.first)
    #expect(operation.operationID == "mobile_get_users_by_id")
    #expect(operation.path == "/app/users/{id}")
    #expect(operation.pathParameters == ["id"])
    #expect(operation.authorization == .roles(["USER"]))
}

@Test func connectCompilerRequiresRevisionAndRejectsOperationIDCollisions() async throws {
    let router = HTTPRouter()
    try await CollisionContractController.__pearfy_registerRoutes(in: router, instance: CollisionContractController())
    try await router.freeze()
    let compiler = PearfyConnectCompiler()

    var revisionRequired = false
    do {
        _ = try await compiler.compile(router: router, buildRevision: "  ")
    } catch PearfyConnectCompilerError.emptyBuildRevision {
        revisionRequired = true
    }
    #expect(revisionRequired)

    var collisionRejected = false
    do {
        _ = try await compiler.compile(router: router, buildRevision: "test-revision")
    } catch PearfyConnectCompilerError.duplicateOperationID {
        collisionRejected = true
    }
    #expect(collisionRejected)
}

@RouteGroup(name: "mobile", prefix: "/app", sdk: [.ios, .android])
private enum MobileContractGroup {}

@RestController("/users", group: MobileContractGroup.self)
private struct MobileContractController: Sendable {
    @Get("/{id}")
    @RolesAllowed("USER")
    func find(@PathVariable id: String) -> String { id }
}

@RouteGroup(name: "internal", prefix: "/internal", sdk: [])
private enum InternalContractGroup {}

@RestController("/metrics", group: InternalContractGroup.self)
private struct InternalContractController: Sendable {
    @Get("/health")
    @PermitAll
    func health() -> String { "ok" }
}

@RouteGroup(name: "collision", prefix: "/collision", sdk: [.typescript])
private enum CollisionContractGroup {}

@RestController("/", group: CollisionContractGroup.self)
private struct CollisionContractController: Sendable {
    @Get("/a/b_c")
    @PermitAll
    func first() -> String { "first" }

    @Get("/a_b/c")
    @PermitAll
    func second() -> String { "second" }
}

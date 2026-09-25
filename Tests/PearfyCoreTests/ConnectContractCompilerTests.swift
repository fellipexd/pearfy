import Foundation
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

@Test func connectCompilerResolvesTypedRequestAndResponseSchemas() async throws {
    let router = HTTPRouter()
    try await ProfileContractController.__pearfy_registerRoutes(in: router, instance: ProfileContractController())
    try await router.freeze()

    let schemas = PearfyGeneratedSchemaRegistry.contractSchemas
    let profileInputSchema = try #require(schemas.first(where: { $0.id == "ProfileInput" }))
    #expect(profileInputSchema.properties["display_name"]?.id == "String")
    let tagsSchemaID = try #require(profileInputSchema.properties["tags"]?.id)
    let expectedTagsSchemaID = PearfyContractSchema.arraySchemaID(for: PearfyContractSchemaReference(id: "String"))
    #expect(tagsSchemaID == expectedTagsSchemaID)
    #expect(schemas.contains(where: { $0.id == expectedTagsSchemaID }))
    let profileOutputSchema = try #require(schemas.first(where: { $0.id == "ProfileOutput" }))
    #expect(profileOutputSchema.properties["metadata"] == PearfyContractSchemaReference(id: "ProfileMetadata", nullable: true))
    #expect(!profileOutputSchema.required.contains("metadata"))
    let compiler = PearfyConnectCompiler()
    let contract = try await compiler.compile(
        router: router,
        buildRevision: "typed-schema-revision",
        schemas: schemas
    )

    #expect(contract.schemaCoverage == .typedSchemaReferences)
    #expect(contract.canGenerateSDKs == false)
    #expect(Set(contract.schemas.map(\.id)).isSuperset(of: ["ProfileInput", "ProfileOutput", "ProfileMetadata", "String", "UUID"]))
    let tagsSchema = try #require(contract.schemas.first(where: { $0.id == tagsSchemaID }))
    #expect(tagsSchema.type == .array)
    #expect(tagsSchema.items?.id == "String")
    let metadataSchema = try #require(contract.schemas.first(where: { $0.id == "ProfileMetadata" }))
    #expect(metadataSchema.properties["timezone"]?.id == "String")
    let createOperation = try #require(contract.operations.first(where: { $0.method == "POST" }))
    #expect(createOperation.requestSchema == PearfyContractSchemaReference(id: "ProfileInput"))
    #expect(createOperation.responseSchema == PearfyContractSchemaReference(id: "ProfileOutput"))

    let listOperation = try #require(contract.operations.first(where: { $0.path == "/profiles/all" }))
    let listSchema = try #require(contract.schemas.first(where: { $0.id == listOperation.responseSchema?.id }))
    #expect(listSchema.type == .array)
    #expect(listSchema.items?.id == "ProfileOutput")

    let findOperation = try #require(contract.operations.first(where: { $0.path == "/profiles/{id}" }))
    #expect(findOperation.responseSchema == PearfyContractSchemaReference(id: "ProfileOutput", nullable: true))

    let reorderedSchemas = Array(schemas.reversed())
    let reorderedContract = try await compiler.compile(
        router: router,
        buildRevision: "typed-schema-revision",
        schemas: reorderedSchemas
    )
    #expect(try contract.canonicalJSON() == reorderedContract.canonicalJSON())

    var missingSchemaRejected = false
    do {
        _ = try await compiler.compile(
            router: router,
            buildRevision: "typed-schema-revision",
            schemas: schemas.filter { $0.id != "ProfileOutput" }
        )
    } catch PearfyConnectCompilerError.missingSchema("ProfileOutput") {
        missingSchemaRejected = true
    }
    #expect(missingSchemaRejected)
}

@RouteGroup(name: "mobile", prefix: "/app", sdk: [.ios, .android])
private enum MobileContractGroup {}

@RestController("/users", group: MobileContractGroup.self)
private struct MobileContractController: Sendable {
    @Get("/{id}")
    @RolesAllowed("USER")
    func find(@PathVariable id: String) -> HTTPResponse { .text(id) }
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

@RouteGroup(name: "profiles", prefix: "/profiles", sdk: [.typescript])
private enum ProfileContractGroup {}

@RestController(group: ProfileContractGroup.self)
private struct ProfileContractController: Sendable {
    @Post
    @PermitAll
    func create(@RequestBody input: ProfileInput) -> ProfileOutput {
        ProfileOutput(id: UUID(), displayName: input.displayName, metadata: nil)
    }

    @Get("/all")
    @PermitAll
    func list() -> [ProfileOutput] { [] }

    @Get("/{id}")
    @PermitAll
    func find(@PathVariable id: String) -> ProfileOutput? { nil }
}

@ContractModel
struct ProfileInput: Codable, Sendable {
    @ContractField(name: "display_name")
    let displayName: String
    let tags: [String]

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case tags
    }
}

@ContractModel
struct ProfileOutput: Codable, Sendable {
    let id: UUID
    let displayName: String
    let metadata: ProfileMetadata?
}

@ContractModel
struct ProfileMetadata: Codable, Sendable {
    let timezone: String?
}

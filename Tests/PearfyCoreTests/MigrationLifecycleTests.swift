import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@Test func missingArchitectureStyleDefaultsToCleanAndExplicitStyleIsPreserved() throws {
    let decoder = JSONDecoder()
    let unspecified = try decoder.decode(
        PearfyProjectManifest.Architecture.self,
        from: Data(#"{"profile":"standard-api"}"#.utf8)
    )
    let configured = try decoder.decode(
        PearfyProjectManifest.Architecture.self,
        from: Data(#"{"style":"hexagonal","profile":"standard-api"}"#.utf8)
    )
    #expect(unspecified.style == "clean")
    #expect(configured.style == "hexagonal")
}

@testable import PearfyCLIKit

@Test func springAnalyzerReconstructsRoutesWithControllerPrefixesAndEvidence() throws {
    let root = try temporaryProject("spring")
    defer { try? FileManager.default.removeItem(at: root) }
    let sources = root.appendingPathComponent("src/main/java/sample", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try "org.springframework.boot:spring-boot-starter-web".write(
        to: root.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8
    )
    try """
    package sample;
    @RestController
    @RequestMapping("/api")
    class UsersController {
        @GetMapping("/users/{id}")
        public User getUser(@PathVariable String id) { return null; }
        @PostMapping("/users")
        public User createUser(@RequestBody User request) { return null; }
    }
    """.write(to: sources.appendingPathComponent("UsersController.java"), atomically: true, encoding: .utf8)
    try """
    package sample;
    @Service
    public class UserService {
        @Transactional
        public void save() {}
        @PreAuthorize("hasRole('ADMIN')")
        public void adminOperation() {}
        @Scheduled(cron = "0 * * * * *")
        public void refresh() {}
        @KafkaListener(topics = "users")
        public void consume() {}
    }
    """.write(to: sources.appendingPathComponent("UserService.java"), atomically: true, encoding: .utf8)
    try "@Repository public interface UserRepository {}".write(to: sources.appendingPathComponent("UserRepository.java"), atomically: true, encoding: .utf8)
    try "@Entity public class User {}".write(to: sources.appendingPathComponent("User.java"), atomically: true, encoding: .utf8)

    let contract = try PearfyLegacyProjectAnalyzer().analyze(projectRoot: root)
    #expect(contract.origin.framework == "spring-boot")
    #expect(contract.origin.language == "java")
    #expect(contract.routes.map(\.key) == ["GET /api/users/{id}", "POST /api/users"])
    #expect(contract.routes.allSatisfy { $0.evidence.contains(where: { $0.path?.hasSuffix("UsersController.java") == true }) })
    #expect(contract.elements.contains { $0.kind == .controller && $0.name == "UsersController" })
    #expect(contract.elements.contains { $0.kind == .service && $0.name == "UserService" })
    #expect(contract.elements.contains { $0.kind == .repository && $0.name == "UserRepository" })
    #expect(contract.elements.contains { $0.kind == .model && $0.name == "User" })
    #expect(contract.elements.contains { $0.kind == .transaction && $0.name == "save" })
    #expect(contract.elements.contains { $0.kind == .securityRule && $0.name == "adminOperation" })
    #expect(contract.elements.contains { $0.kind == .job && $0.name == "refresh" })
    #expect(contract.elements.contains { $0.kind == .event && $0.name == "consume" })
    #expect(PearfyMigrationProgress(routes: contract.routes, elements: contract.elements).elements["service"]?.total == 1)
}

@Test func migrationMacroGuidancePrefersSupportedRouteMacrosWithoutChangingContract() throws {
    let route = PearfyLegacyRouteContract(
        id: "users.getByID",
        method: "GET",
        path: "/users/{id}"
    )
    let original = route
    let guidance = PearfyMacroMigrationGuidance.route(method: route.method, path: route.path)

    #expect(guidance.status == .applicable)
    #expect(guidance.guidance.contains("@RestController + @Get"))
    #expect(guidance.guidance.contains("does not generate or rewrite handlers"))
    #expect(route == original)
}

@Test func migrationMacroGuidanceReportsUnsupportedRouteAndElementSemantics() throws {
    let headRoute = PearfyMacroMigrationGuidance.route(method: "HEAD", path: "/health")
    #expect(headRoute.status == .notSupported)
    #expect(headRoute.statusLine.contains("no public Pearfy controller macro maps HTTP HEAD"))

    let securityElement = PearfyLegacyElementContract(
        id: "security-rule:Users.java:admin:PreAuthorize",
        kind: .securityRule,
        name: "admin",
        attributes: ["annotation": .string("PreAuthorize")]
    )
    let securityGuidance = PearfyMacroMigrationGuidance.element(securityElement)
    #expect(securityGuidance.status == .notSupported)
    #expect(securityGuidance.guidance.contains("cannot prove equivalent principal, expression, and middleware semantics"))

    let transactionElement = PearfyLegacyElementContract(
        id: "transaction:UserService.java:transfer",
        kind: .transaction,
        name: "transfer",
        attributes: ["annotation": .string("Transactional")]
    )
    let transactionGuidance = PearfyMacroMigrationGuidance.element(transactionElement)
    #expect(transactionGuidance.status == .notSupported)
    #expect(transactionGuidance.guidance.contains("no public Pearfy transaction macro exists"))
    #expect(!transactionGuidance.guidance.contains("@Transactional"))

    let externalDependency = PearfyLegacyElementContract(
        id: "external-dependency:vendor",
        kind: .externalDependency,
        name: "vendor"
    )
    #expect(PearfyMacroMigrationGuidance.element(externalDependency).status == .notApplicable)
}

@Test func analyzerIngestsYAMLOpenAPIAndRetainsParameterExamples() throws {
    let root = try temporaryProject("openapi")
    defer { try? FileManager.default.removeItem(at: root) }
    let yaml = """
    openapi: 3.0.0
    info:
      title: Fixture API
      version: v1
    paths:
      /users/{id}:
        get:
          operationId: users.getById
          parameters:
            - name: id
              in: path
              required: true
              schema:
                type: string
                example: demo-123
          responses:
            "200":
              description: Found
              content:
                application/json:
                  schema:
                    type: object
                    properties:
                      id:
                        type: string
    """
    try yaml.write(to: root.appendingPathComponent("openapi.yaml"), atomically: true, encoding: .utf8)

    let contract = try PearfyLegacyProjectAnalyzer().analyze(projectRoot: root)
    #expect(contract.routes.count == 1)
    #expect(contract.routes[0].id == "users.getById")
    #expect(contract.routes[0].parameters.first?.example == .string("demo-123"))
    #expect(contract.routes[0].responses["200"]?.description == "Found")
    #expect(contract.routes[0].state == .contracted)
}

@Test func nodeAndPHPGenericAnalyzersDoNotRequireFrameworkDetection() throws {
    let nodeRoot = try temporaryProject("generic-node")
    defer { try? FileManager.default.removeItem(at: nodeRoot) }
    let node = nodeRoot.appendingPathComponent("server.js")
    try "const app = makeRouter(); app.get('/health', handler); app.post('/users', create);".write(to: node, atomically: true, encoding: .utf8)
    let nodeContract = try PearfyLegacyProjectAnalyzer().analyze(projectRoot: nodeRoot)
    #expect(nodeContract.routes.map(\.key) == ["GET /health", "POST /users"])

    let phpRoot = try temporaryProject("generic-php")
    defer { try? FileManager.default.removeItem(at: phpRoot) }
    let php = phpRoot.appendingPathComponent("index.php")
    try "<?php if ($_SERVER['REQUEST_METHOD'] === 'GET' && $_SERVER['REQUEST_URI'] === '/health') { echo 'ok'; }".write(to: php, atomically: true, encoding: .utf8)
    let phpContract = try PearfyLegacyProjectAnalyzer().analyze(projectRoot: phpRoot)
    #expect(phpContract.routes.map(\.key) == ["GET /health"])
}

@Test func tierAMigratorAdaptersExtractNestFastAPIASPNETAndLaravelRoutes() throws {
    let root = try temporaryProject("tier-a-routes")
    defer { try? FileManager.default.removeItem(at: root) }
    try "{\"dependencies\":{\"@nestjs/common\":\"^10.0.0\"}}".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try """
    @Controller('/users')
    export class UsersController {
      @Get(':id')
      getOne() {}
      @Post()
      create() {}
    }
    """.write(to: root.appendingPathComponent("users.controller.ts"), atomically: true, encoding: .utf8)
    try "fastapi==0.115\n".write(to: root.appendingPathComponent("requirements.txt"), atomically: true, encoding: .utf8)
    try "@app.get('/health')\ndef health(): return {'ok': True}\n".write(to: root.appendingPathComponent("api.py"), atomically: true, encoding: .utf8)
    try "<Project><PackageReference Include=\"Microsoft.AspNetCore.App\" /></Project>".write(to: root.appendingPathComponent("api.csproj"), atomically: true, encoding: .utf8)
    try """
    [ApiController]
    [Route("api/[controller]")]
    public class UsersController : ControllerBase {
      [HttpGet("{id}")]
      public IActionResult GetUser(string id) => Ok();
      [Authorize(Roles = "Admin")]
      [HttpPost]
      public IActionResult Create() => Ok();
    }
    """.write(to: root.appendingPathComponent("UsersController.cs"), atomically: true, encoding: .utf8)
    try "package example.test/api\n\nr.GET(\"/ping\", handler)\n".write(to: root.appendingPathComponent("routes.go"), atomically: true, encoding: .utf8)
    let routesDirectory = root.appendingPathComponent("routes", isDirectory: true)
    try FileManager.default.createDirectory(at: routesDirectory, withIntermediateDirectories: true)
    try "Route::get('/orders/{id}', [OrderController::class, 'show']);".write(to: routesDirectory.appendingPathComponent("api.php"), atomically: true, encoding: .utf8)

    let contract = try PearfyLegacyProjectAnalyzer().analyze(projectRoot: root)
    let keys = Set(contract.routes.map(\.key))
    #expect(keys.contains("GET /users/{id}"))
    #expect(keys.contains("POST /users"))
    #expect(keys.contains("GET /health"))
    #expect(keys.contains("GET /api/Users/{id}"))
    #expect(keys.contains("POST /api/Users"))
    #expect(keys.contains("GET /ping"))
    #expect(keys.contains("GET /orders/{id}"))
    #expect(contract.elements.contains(where: { $0.kind == .securityRule && $0.name == "Create" }))
}

@Test func postmanAndDatabaseMigrationEvidenceIsContractedWithoutRetainingSampleValues() throws {
    let root = try temporaryProject("postman-ddl")
    defer { try? FileManager.default.removeItem(at: root) }
    let postman = [
        "info": ["schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"],
        "item": [[
            "name": "Get user",
            "request": [
                "method": "POST",
                "header": [
                    ["key": "Authorization", "value": "Bearer private-token"],
                    ["key": "Content-Type", "value": "application/json"]
                ],
                "body": ["mode": "raw", "raw": #"{"email":"private@example.test","password":"private-password"}"#],
                "url": [
                    "raw": "https://api.example.test/users/:id?account=private-account",
                    "path": ["users", ":id"],
                    "query": [["key": "account", "value": "private-account"]]
                ]
            ],
            "response": [[
                "name": "Created",
                "code": 201,
                "header": [["key": "Content-Type", "value": "application/json"]],
                "body": #"{"id":"user-private-id"}"#
            ]]
        ]]
    ] as [String: Any]
    let postmanData = try JSONSerialization.data(withJSONObject: postman)
    try postmanData.write(to: root.appendingPathComponent("postman_collection.json"))
    let migrationDirectory = root.appendingPathComponent("db/migration", isDirectory: true)
    try FileManager.default.createDirectory(at: migrationDirectory, withIntermediateDirectories: true)
    try "CREATE TABLE public.users (id UUID PRIMARY KEY, password TEXT);".write(
        to: migrationDirectory.appendingPathComponent("V1__create_users.sql"), atomically: true, encoding: .utf8
    )

    let contract = try PearfyLegacyProjectAnalyzer().analyze(projectRoot: root)
    #expect(contract.routes.map(\.key) == ["POST /users/{id}"])
    #expect(contract.routes[0].parameters.contains(where: { $0.location == "query" && $0.example == nil }))
    #expect(contract.elements.contains(where: { $0.kind == .model && $0.name == "public.users" }))
    let persistedContract = String(decoding: try PearfyMigrationDocumentStore.encode(contract), as: UTF8.self)
    #expect(!persistedContract.contains("private-token"))
    #expect(!persistedContract.contains("private-password"))
    #expect(!persistedContract.contains("private@example.test"))
    #expect(!persistedContract.contains("private-account"))
    #expect(!persistedContract.contains("user-private-id"))
}

@Test func sqlAndLiquibaseArtifactsContributeOnlySafeTableMetadata() throws {
    let root = try temporaryProject("database-evidence")
    defer { try? FileManager.default.removeItem(at: root) }
    let migrationDirectory = root.appendingPathComponent("db/migration", isDirectory: true)
    try FileManager.default.createDirectory(at: migrationDirectory, withIntermediateDirectories: true)
    try "CREATE TABLE public.accounts (id UUID PRIMARY KEY, password TEXT);".write(
        to: migrationDirectory.appendingPathComponent("V1__accounts.sql"), atomically: true, encoding: .utf8
    )
    try """
    <databaseChangeLog>
      <changeSet id="2" author="sample">
        <createTable tableName="audit_entries"/>
      </changeSet>
    </databaseChangeLog>
    """.write(to: root.appendingPathComponent("db.changelog-master.xml"), atomically: true, encoding: .utf8)

    let contract = try PearfyLegacyProjectAnalyzer().analyze(projectRoot: root)
    #expect(contract.elements.contains { $0.kind == .model && $0.name == "public.accounts" })
    #expect(contract.elements.contains { $0.kind == .model && $0.name == "audit_entries" })
    let serialized = String(decoding: try PearfyMigrationDocumentStore.encode(contract), as: UTF8.self)
    #expect(!serialized.contains("password TEXT"))
    #expect(!serialized.contains("CREATE TABLE"))
}

@Test func baselineWritesVersionedManifestAndContractWithoutChangingApplicationSource() async throws {
    let root = try temporaryProject("baseline")
    defer { try? FileManager.default.removeItem(at: root) }
    let package = """
    // swift-tools-version: 6.2
    import PackageDescription
    let package = Package(name: "sample", dependencies: [.package(name: "Pearfy", path: "../..")], targets: [.target(name: "sample", dependencies: [.product(name: "PearfyWeb", package: "Pearfy")])])
    """
    try package.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    let source = root.appendingPathComponent("Sources/sample.swift")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "import PearfyWeb\nstruct HealthRoute {}\n".write(to: source, atomically: true, encoding: .utf8)
    try """
    {"openapi":"3.0.0","info":{"title":"sample","version":"1"},"paths":{"/health":{"get":{"operationId":"health","responses":{"200":{"description":"OK"}}}}}}
    """.write(to: root.appendingPathComponent("openapi.json"), atomically: true, encoding: .utf8)
    let originalPackage = try Data(contentsOf: root.appendingPathComponent("Package.swift"))
    let frameworkRoot = ProjectScaffolder.frameworkRootFromSourceFile(#filePath)

    #expect(try await PearfyProjectLifecycleCommand.run(
        command: "baseline",
        arguments: [],
        projectRoot: root,
        frameworkRoot: frameworkRoot
    ) == 0)

    let manifest = try PearfyMigrationDocumentStore.load(
        PearfyProjectManifest.self,
        from: root.appendingPathComponent("pearfy.project.yml")
    )
    let contract = try PearfyMigrationDocumentStore.load(
        PearfyLegacyContractDocument.self,
        from: root.appendingPathComponent(".pearfy/migration/legacy-contract.yml")
    )
    #expect(manifest.project.mode == .baseline)
    #expect(manifest.architecture.style == "clean")
    #expect(manifest.pearfy.frameworkVersion == "0.1.0")
    #expect(manifest.origin.type == "pearfy")
    #expect(contract.routes.map(\.key) == ["GET /health"])
    #expect(try Data(contentsOf: root.appendingPathComponent("Package.swift")) == originalPackage)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".pearfy/history.jsonl").path))
}

@Test func adoptAddsTraceabilityToAnExistingPearfyPackageWithoutEditingItsManifest() async throws {
    let root = try temporaryProject("adopt")
    defer { try? FileManager.default.removeItem(at: root) }
    let package = """
    // swift-tools-version: 6.2
    import PackageDescription
    let package = Package(name: "existing-api", dependencies: [.package(name: "Pearfy", path: "../..")], targets: [.target(name: "existing-api", dependencies: [.product(name: "PearfyWeb", package: "Pearfy")])])
    """
    try package.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try "import PearfyWeb\nstruct HealthRoute {}\n".write(to: root.appendingPathComponent("HealthRoute.swift"), atomically: true, encoding: .utf8)
    try openAPIFixture(paths: ["/health": ["get": operation("health")]]).write(to: root.appendingPathComponent("openapi.json"), options: .atomic)

    #expect(try await PearfyProjectLifecycleCommand.run(
        command: "adopt",
        arguments: [],
        projectRoot: root,
        frameworkRoot: ProjectScaffolder.frameworkRootFromSourceFile(#filePath)
    ) == 0)

    let manifest = try PearfyMigrationDocumentStore.load(PearfyProjectManifest.self, from: root.appendingPathComponent("pearfy.project.yml"))
    #expect(manifest.project.mode == .adopt)
    #expect(manifest.project.name == "existing-api")
    #expect(try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8) == package)
}

@Test func inspectIsReadOnlyAndRouteProgressRequiresOrderedTransitions() async throws {
    let root = try temporaryProject("inspect")
    defer { try? FileManager.default.removeItem(at: root) }
    try openAPIFixture(paths: ["/health": ["get": operation("health")]]).write(to: root.appendingPathComponent("openapi.json"), options: .atomic)
    #expect(try await PearfyProjectLifecycleCommand.run(
        command: "inspect",
        arguments: [],
        projectRoot: root,
        frameworkRoot: root
    ) == 0)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("pearfy.project.yml").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".pearfy").path))

    let packageRoot = try temporaryProject("route-state")
    defer { try? FileManager.default.removeItem(at: packageRoot) }
    try "let package = Package(name: \"route-state\", dependencies: [.product(name: \"PearfyWeb\", package: \"Pearfy\")])".write(
        to: packageRoot.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8
    )
    try openAPIFixture(paths: ["/health": ["get": operation("health")]]).write(to: packageRoot.appendingPathComponent("openapi.json"), options: .atomic)
    #expect(try await PearfyProjectLifecycleCommand.run(
        command: "baseline",
        arguments: [],
        projectRoot: packageRoot,
        frameworkRoot: packageRoot
    ) == 0)
    #expect(try await PearfyProjectLifecycleCommand.run(
        command: "migrate",
        arguments: ["route", "--route", "GET /health", "--state", "mapped"],
        projectRoot: packageRoot,
        frameworkRoot: packageRoot
    ) == 0)
    #expect(try await PearfyProjectLifecycleCommand.run(
        command: "migrate",
        arguments: ["route", "--route", "GET /health", "--state", "implemented"],
        projectRoot: packageRoot,
        frameworkRoot: packageRoot
    ) == 0)
    let contract = try PearfyMigrationDocumentStore.load(
        PearfyLegacyContractDocument.self,
        from: packageRoot.appendingPathComponent(".pearfy/migration/legacy-contract.yml")
    )
    #expect(contract.routes.first?.state == .implemented)
}

@Test func syncPreservesExistingRouteProgressAndAddsNewlyDiscoveredRoutes() async throws {
    let root = try temporaryProject("sync")
    defer { try? FileManager.default.removeItem(at: root) }
    try "let package = Package(name: \"sample\", dependencies: [.product(name: \"PearfyWeb\", package: \"Pearfy\")])".write(
        to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8
    )
    let api = root.appendingPathComponent("openapi.json")
    try openAPIFixture(paths: ["/health": ["get": operation("health")]]).write(to: api, options: .atomic)
    let frameworkRoot = ProjectScaffolder.frameworkRootFromSourceFile(#filePath)
    #expect(try await PearfyProjectLifecycleCommand.run(command: "baseline", arguments: [], projectRoot: root, frameworkRoot: frameworkRoot) == 0)

    let contractURL = root.appendingPathComponent(".pearfy/migration/legacy-contract.yml")
    var contract = try PearfyMigrationDocumentStore.load(PearfyLegacyContractDocument.self, from: contractURL)
    contract.routes[0].state = .implemented
    try PearfyMigrationDocumentStore.write(contract, to: contractURL)
    try openAPIFixture(paths: [
        "/health": ["get": operation("health")],
        "/users": ["get": operation("users.list")]
    ]).write(to: api, options: .atomic)

    #expect(try await PearfyProjectLifecycleCommand.run(command: "sync", arguments: ["--apply"], projectRoot: root, frameworkRoot: frameworkRoot) == 0)
    let synced = try PearfyMigrationDocumentStore.load(PearfyLegacyContractDocument.self, from: contractURL)
    #expect(synced.routes.first(where: { $0.key == "GET /health" })?.state == .implemented)
    #expect(synced.routes.first(where: { $0.key == "GET /users" })?.state == .contracted)
}

@Test func e2eVerifyWithoutEndpointsIsIncompleteAndDoesNotClaimRouteClosure() async throws {
    let root = try temporaryProject("e2e-incomplete")
    defer { try? FileManager.default.removeItem(at: root) }
    try "let package = Package(name: \"sample\", dependencies: [.product(name: \"PearfyWeb\", package: \"Pearfy\")])".write(
        to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8
    )
    try openAPIFixture(paths: ["/health": ["get": operation("health")]]).write(to: root.appendingPathComponent("openapi.json"), options: .atomic)
    let frameworkRoot = ProjectScaffolder.frameworkRootFromSourceFile(#filePath)
    #expect(try await PearfyProjectLifecycleCommand.run(command: "baseline", arguments: [], projectRoot: root, frameworkRoot: frameworkRoot) == 0)

    let contractURL = root.appendingPathComponent(".pearfy/migration/legacy-contract.yml")
    var contract = try PearfyMigrationDocumentStore.load(PearfyLegacyContractDocument.self, from: contractURL)
    contract.routes[0].state = .implemented
    try PearfyMigrationDocumentStore.write(contract, to: contractURL)
    #expect(try await PearfyProjectLifecycleCommand.run(
        command: "migrate",
        arguments: ["verify", "--route", "GET /health"],
        projectRoot: root,
        frameworkRoot: frameworkRoot,
        environment: [:]
    ) == 2)
    let after = try PearfyMigrationDocumentStore.load(PearfyLegacyContractDocument.self, from: contractURL)
    #expect(after.routes[0].state == .implemented)
}

@Test func e2eSemanticNormalizerIgnoresConfiguredDynamicFieldsAndUnorderedArrays() throws {
    let decoder = JSONDecoder()
    let left = try decoder.decode(PearfyMigrationJSONValue.self, from: Data(#"{"requestId":"a","roles":["writer","reader"],"createdAt":"2025-01-02T03:04:05Z"}"#.utf8))
    let right = try decoder.decode(PearfyMigrationJSONValue.self, from: Data(#"{"requestId":"b","roles":["reader","writer"],"createdAt":"2026-08-09T10:11:12Z"}"#.utf8))
    let normalizedLeft = MigrationHTTPComparison.normalizeContractValue(
        left,
        path: "$",
        ignore: ["$.requestId"],
        unordered: ["$.roles"],
        normalizeTimestamps: true
    )
    let normalizedRight = MigrationHTTPComparison.normalizeContractValue(
        right,
        path: "$",
        ignore: ["$.requestId"],
        unordered: ["$.roles"],
        normalizeTimestamps: true
    )
    #expect(normalizedLeft == normalizedRight)
}

@Test func e2eComparatorExecutesBothRequestsAndAppliesConfiguredSemanticRules() async throws {
    let root = try temporaryProject("e2e-compare")
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = """
    {"comparison":{"ignore":["$.requestId"],"timestamps":{"normalize":true},"arrays":{"$.roles":{"order":"ignored"}}}}
    """
    try Data(settings.utf8).write(to: root.appendingPathComponent("settings.yml"))
    let route = PearfyLegacyRouteContract(
        id: "users.getById",
        method: "GET",
        path: "/users/{id}",
        parameters: [PearfyLegacyParameterContract(
            name: "id",
            location: "path",
            required: true,
            schema: .object(["type": .string("string")]),
            example: .string("demo-123")
        )],
        state: .implemented
    )
    let legacyBody = Data(#"{"requestId":"legacy-id","roles":["writer","reader"],"createdAt":"2025-01-02T03:04:05Z"}"#.utf8)
    let pearfyBody = Data(#"{"requestId":"pearfy-id","roles":["reader","writer"],"createdAt":"2026-08-09T10:11:12Z"}"#.utf8)
    let result = try await MigrationHTTPComparison.compare(
        route: route,
        baseURLs: .init(legacy: URL(string: "https://legacy.example.test")!, pearfy: URL(string: "https://pearfy.example.test")!),
        environment: [
            "PEARFY_MIGRATION_ALLOW_REMOTE": "1",
            "PEARFY_MIGRATION_E2E_SETTINGS": root.appendingPathComponent("settings.yml").path
        ],
        allowWrites: false,
        responder: { request in
            guard request.url?.path == "/users/demo-123" else { throw MigrationHTTPComparisonError.invalidResponse }
            let body = request.url?.host == "legacy.example.test" ? legacyBody : pearfyBody
            return MigrationHTTPComparison.Response(status: 200, headers: ["content-type": "application/json"], body: body)
        }
    )

    #expect(result.outcome == .verified)
    #expect(result.mismatches.isEmpty)
    #expect(result.comparedResponseBytes == legacyBody.count + pearfyBody.count)
}

private func temporaryProject(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pearfy-migration-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func operation(_ operationID: String) -> [String: Any] {
    ["operationId": operationID, "responses": ["200": ["description": "OK"]]]
}

private func openAPIFixture(paths: [String: [String: [String: Any]]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "openapi": "3.0.0",
        "info": ["title": "Fixture", "version": "1"],
        "paths": paths
    ], options: [.sortedKeys])
}

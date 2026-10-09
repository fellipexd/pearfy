import Foundation
import PearfyCLIKit
import Testing

@Test func projectScaffolderCreatesARegistryBackedSwiftPackage() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-cli-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let frameworkRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let destination = temporaryRoot.appendingPathComponent("sample-api", isDirectory: true)
    _ = try ProjectScaffolder(frameworkRoot: frameworkRoot).createProject(named: "sample-api", at: destination)

    let manifest = try String(contentsOf: destination.appendingPathComponent("Package.swift"), encoding: .utf8)
    let service = try String(contentsOf: destination.appendingPathComponent("Sources/SampleApi/Application/GreetingService.swift"), encoding: .utf8)
    let controller = try String(contentsOf: destination.appendingPathComponent("Sources/SampleApi/Presentation/GreetingController.swift"), encoding: .utf8)
    let bootstrap = try String(contentsOf: destination.appendingPathComponent("Sources/SampleApi/Infrastructure/PearfyApplicationBootstrap.swift"), encoding: .utf8)
    let readme = try String(contentsOf: destination.appendingPathComponent("README.md"), encoding: .utf8)
    #expect(manifest.contains(".package("))
    #expect(manifest.contains("path: \"\(frameworkRoot.path)\""))
    #expect(manifest.contains("traits: ["))
    #expect(manifest.contains("pearfy-package-traits:begin"))
    #expect(manifest.contains("\"Crypto\","))
    #expect(!manifest.contains("\"GameServerGRPC\","))
    #expect(manifest.contains("PearfyDiscoveryPlugin"))
    #expect(manifest.contains("PearfyNIO"))
    #expect(manifest.contains(".product(name: \"PearfyDI\", package: \"Pearfy\")"))
    #expect(manifest.contains("pearfy-modules:begin"))
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".pearfy/modules.json").path))
    #expect(service.contains("@Service"))
    #expect(controller.contains("@RestController"))
    #expect(controller.contains("@Get(\"/{name}\")"))
    #expect(controller.contains("@PathVariable name: String"))
    #expect(controller.contains("@PermitAll"))
    #expect(bootstrap.contains("PearfyGeneratedRegistry.registerComponents(in: container)"))
    #expect(bootstrap.contains("GreetingController.__pearfy_registerRoutes("))
    #expect(!bootstrap.contains("router.get("))
    #expect(readme.contains("Clean Architecture by default"))
    #expect(readme.contains("No persistence repository is added"))
}

@Test func moduleManagerPlansDependenciesAndAppliesOnlyManagedPackageProducts() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-module-manager-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let frameworkRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let projectRoot = temporaryRoot.appendingPathComponent("module-api", isDirectory: true)
    _ = try ProjectScaffolder(frameworkRoot: frameworkRoot)
        .createProject(named: "module-api", at: projectRoot)

    let manager = try PearfyModuleManager()
    #expect(try manager.doctor(projectRoot: projectRoot) == ["http"])

    let postgresPlan = try manager.planAdding("postgres", to: ["http"])
    #expect(postgresPlan.productsToAdd == ["PearfyData", "PearfyPostgres", "PearfyTransactions"])
    #expect(postgresPlan.packageTraitsToEnable == ["Postgres"])
    try manager.apply(postgresPlan, to: projectRoot)
    #expect(try manager.doctor(projectRoot: projectRoot) == ["http", "postgres"])
    let repeatedPostgresPlan = try manager.planAdding("postgres", to: ["http", "postgres"])
    #expect(repeatedPostgresPlan.productsToAdd.isEmpty)

    let aiPlan = try manager.planAdding("ai", to: ["http", "postgres"])
    #expect(aiPlan.plannedModules == ["ai", "http", "postgres"])
    #expect(aiPlan.productsToAdd == ["PearfyAI", "PearfyCloud"])
    try manager.apply(aiPlan, to: projectRoot)
    #expect(try manager.doctor(projectRoot: projectRoot) == ["ai", "http", "postgres"])

    var requiredCloudRejected = false
    do {
        _ = try manager.planRemoving("cloud", from: ["ai", "http", "postgres"])
    } catch PearfyModuleManagerError.requiredModule("cloud", by: ["ai"]) {
        requiredCloudRejected = true
    }
    #expect(requiredCloudRejected)
    let repeatedRemoval = try manager.planRemoving("jobs", from: ["http", "postgres"])
    #expect(repeatedRemoval.productsToAdd.isEmpty)
    #expect(repeatedRemoval.productsToRemove.isEmpty)

    let packageManifest = try String(contentsOf: projectRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
    #expect(packageManifest.contains(".product(name: \"PearfyData\", package: \"Pearfy\")"))
    #expect(packageManifest.contains(".product(name: \"PearfyCloud\", package: \"Pearfy\")"))
    #expect(packageManifest.contains("\"Postgres\","))
    #expect(!packageManifest.contains("\"GameServerGRPC\","))

    let grpcPlan = try manager.planAdding("gameserver-grpc", to: ["http"])
    #expect(grpcPlan.packageTraitsToEnable == ["GameServerGRPC"])
    #expect(grpcPlan.productsToAdd.contains("PearfyGameServer"))
    #expect(grpcPlan.productsToAdd.contains("PearfyGameServerGRPC"))

    guard let packageStart = packageManifest.range(of: ".package("),
          let packageEnd = packageManifest.range(of: "\n        )", range: packageStart.lowerBound..<packageManifest.endIndex) else {
        Issue.record("Expected generated multiline Pearfy package dependency")
        return
    }
    var legacyManifest = packageManifest
    legacyManifest.replaceSubrange(
        packageStart.lowerBound..<packageEnd.upperBound,
        with: ".package(name: \"Pearfy\", path: \"\(frameworkRoot.path)\")"
    )
    try legacyManifest.write(to: projectRoot.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    #expect(try manager.doctor(projectRoot: projectRoot) == ["ai", "http", "postgres"])
    let legacyUpgradePlan = try manager.planAdding("ai", to: ["ai", "http", "postgres"])
    try manager.apply(legacyUpgradePlan, to: projectRoot)
    let upgradedManifest = try String(contentsOf: projectRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
    #expect(upgradedManifest.contains("pearfy-package-traits:begin"))
    #expect(upgradedManifest.contains("\"Postgres\","))
}

@Test func projectScaffolderRejectsExistingDestinationsWithoutOverwriting() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-cli-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    let destination = temporaryRoot.appendingPathComponent("existing", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let marker = destination.appendingPathComponent("keep.txt")
    try "keep".write(to: marker, atomically: true, encoding: .utf8)

    let frameworkRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    var rejected = false
    do {
        _ = try ProjectScaffolder(frameworkRoot: frameworkRoot).createProject(named: "existing", at: destination)
    } catch ProjectScaffoldError.destinationExists {
        rejected = true
    }
    #expect(rejected)
    #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
}

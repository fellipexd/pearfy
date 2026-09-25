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
    let source = try String(contentsOf: destination.appendingPathComponent("Sources/SampleApi/main.swift"), encoding: .utf8)
    #expect(manifest.contains(".package(name: \"Pearfy\", path:"))
    #expect(manifest.contains("PearfyDiscoveryPlugin"))
    #expect(manifest.contains("PearfyNIO"))
    #expect(manifest.contains("pearfy-modules:begin"))
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".pearfy/modules.json").path))
    #expect(source.contains("__pearfy_registerRoutes"))
    #expect(source.contains("@RestController"))
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

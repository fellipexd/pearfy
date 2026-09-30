import Foundation
import PearfyCLIKit
import Testing

@Test func populateModuleAddsOnlyItsPostgresAndDataDependencies() throws {
    let manager = try PearfyModuleManager()
    let plan = try manager.planAdding("populate", to: ["http"])

    #expect(plan.plannedModules == ["http", "populate"])
    #expect(Set(plan.productsToAdd) == [
        "PearfyData",
        "PearfyPostgres",
        "PearfyPopulateCore",
        "PearfyPopulatePostgres",
        "PearfyTransactions"
    ])
}

@Test func populateModuleRemainsAbsentUntilSelectedInAManagedProject() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-populate-module-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let frameworkRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let projectRoot = root.appendingPathComponent("module-api", isDirectory: true)
    _ = try ProjectScaffolder(frameworkRoot: frameworkRoot).createProject(named: "module-api", at: projectRoot)
    let packageURL = projectRoot.appendingPathComponent("Package.swift")
    let original = try String(contentsOf: packageURL, encoding: .utf8)
    #expect(!original.contains("PearfyPopulateCore"))

    let manager = try PearfyModuleManager()
    let plan = try manager.planAdding("populate", to: ["http"])
    try manager.apply(plan, to: projectRoot)

    let updated = try String(contentsOf: packageURL, encoding: .utf8)
    #expect(updated.contains(".product(name: \"PearfyPopulateCore\", package: \"Pearfy\")"))
    #expect(updated.contains(".product(name: \"PearfyPopulatePostgres\", package: \"Pearfy\")"))
    #expect(try manager.doctor(projectRoot: projectRoot) == ["http", "populate"])
}

@Test func moduleChangesInstallOnlyTheirSkillsWithoutInitializingAnAIClient() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-module-skill-sync-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let frameworkRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let projectRoot = root.appendingPathComponent("module-api", isDirectory: true)
    _ = try ProjectScaffolder(frameworkRoot: frameworkRoot).createProject(named: "module-api", at: projectRoot)

    let manager = try PearfyModuleManager()
    try manager.apply(try manager.planAdding("populate", to: ["http"]), to: projectRoot)
    #expect(try PearfyAICommand.syncAfterModuleChange(projectRoot: projectRoot, frameworkRoot: frameworkRoot) == 0)

    #expect(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(".agents/skills/pearfy-core/SKILL.md").path))
    #expect(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(".agents/skills/pearfy-populate/SKILL.md").path))
    #expect(!FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(".agents/agents").path))
    #expect(!FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("AGENTS.md").path))
    let state = try #require(JSONSerialization.jsonObject(
        with: Data(contentsOf: projectRoot.appendingPathComponent(".pearfy/ai.json"))
    ) as? [String: Any])
    #expect(state["initialized"] as? Bool == false)
    #expect(state["client"] as? String == "generic")
}

@Test func aiSyncInstallsOnlySelectedSkillsAndPreservesUserEditsUntilExplicitForce() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-ai-sync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let frameworkRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let projectRoot = root.appendingPathComponent("sample-api", isDirectory: true)
    _ = try ProjectScaffolder(frameworkRoot: frameworkRoot).createProject(named: "sample-api", at: projectRoot)
    #expect(try PearfyAICommand.run(
        arguments: ["init", "--client", "opencode"],
        projectRoot: projectRoot,
        frameworkRoot: frameworkRoot
    ) == 0)

    let coreSkill = projectRoot.appendingPathComponent(".agents/skills/pearfy-core/SKILL.md")
    let populateSkill = projectRoot.appendingPathComponent(".agents/skills/pearfy-populate/SKILL.md")
    #expect(FileManager.default.fileExists(atPath: coreSkill.path))
    #expect(!FileManager.default.fileExists(atPath: populateSkill.path))
    let openCodeConfig = try #require(JSONSerialization.jsonObject(
        with: Data(contentsOf: projectRoot.appendingPathComponent("opencode.json"))
    ) as? [String: Any])
    let mcp = try #require(openCodeConfig["mcp"] as? [String: Any])
    let pearfyServer = try #require(mcp["pearfy"] as? [String: Any])
    #expect(pearfyServer["enabled"] as? Bool == false)

    let customReference = projectRoot.appendingPathComponent(".agents/skills/pearfy-core/references/custom.md")
    try "developer-owned reference".write(to: customReference, atomically: true, encoding: .utf8)
    try "# Developer customization".write(to: coreSkill, atomically: true, encoding: .utf8)

    let manager = try PearfyModuleManager()
    try manager.apply(try manager.planAdding("populate", to: ["http"]), to: projectRoot)
    #expect(try PearfyAICommand.syncAfterModuleChange(projectRoot: projectRoot, frameworkRoot: frameworkRoot) == 1)
    #expect(FileManager.default.fileExists(atPath: populateSkill.path))
    #expect(try String(contentsOf: coreSkill, encoding: .utf8) == "# Developer customization")
    #expect(try String(contentsOf: customReference, encoding: .utf8) == "developer-owned reference")
    #expect(try PearfyAICommand.run(arguments: ["doctor"], projectRoot: projectRoot, frameworkRoot: frameworkRoot) == 2)

    #expect(try PearfyAICommand.run(arguments: ["sync", "--force"], projectRoot: projectRoot, frameworkRoot: frameworkRoot) == 0)
    #expect(try Data(contentsOf: coreSkill) == Data(contentsOf: frameworkRoot.appendingPathComponent(".agents/skills/pearfy-core/SKILL.md")))
    #expect(try String(contentsOf: customReference, encoding: .utf8) == "developer-owned reference")
    #expect(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(".opencode/skills/pearfy-populate").path))
    #expect(try PearfyAICommand.run(arguments: ["doctor"], projectRoot: projectRoot, frameworkRoot: frameworkRoot) == 0)
}

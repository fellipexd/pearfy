import Foundation
import PearfyCLIKit
import Testing

@Test func aiInitPreservesUserInstructionsAndOpenCodeSettingsAndDefaultsPearfyMCPOff() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-ai-init-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let frameworkRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let projectRoot = root.appendingPathComponent("sample-api", isDirectory: true)
    _ = try ProjectScaffolder(frameworkRoot: frameworkRoot).createProject(named: "sample-api", at: projectRoot)

    try "# My project instructions\nKeep my local conventions.".write(
        to: projectRoot.appendingPathComponent("AGENTS.md"),
        atomically: true,
        encoding: .utf8
    )
    let customConfig: [String: Any] = [
        "$schema": "https://opencode.ai/config.json",
        "model": "local/custom",
        "mcp": [
            "pearfy": ["type": "local", "command": ["custom-pearfy", "mcp"], "enabled": true, "timeout": 1234],
            "other-service": ["type": "local", "command": ["custom-service"], "enabled": true]
        ]
    ]
    let configURL = projectRoot.appendingPathComponent("opencode.json")
    try JSONSerialization.data(withJSONObject: customConfig, options: [.prettyPrinted, .sortedKeys]).write(to: configURL)

    #expect(try PearfyAICommand.run(arguments: ["init", "--client", "opencode"], projectRoot: projectRoot, frameworkRoot: frameworkRoot) == 0)

    let instructions = try String(contentsOf: projectRoot.appendingPathComponent("AGENTS.md"), encoding: .utf8)
    #expect(instructions.contains("Keep my local conventions."))
    #expect(instructions.contains("pearfy-ai-context:start"))
    let resolvedConfig = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
    #expect(resolvedConfig["model"] as? String == "local/custom")
    let servers = try #require(resolvedConfig["mcp"] as? [String: Any])
    let pearfy = try #require(servers["pearfy"] as? [String: Any])
    let other = try #require(servers["other-service"] as? [String: Any])
    #expect(pearfy["command"] as? [String] == ["custom-pearfy", "mcp"])
    #expect(pearfy["enabled"] as? Bool == false)
    #expect(other["enabled"] as? Bool == true)

    let manager = try PearfyModuleManager()
    let lock = try #require(try manager.projectModuleVersions(projectRoot: projectRoot))
    #expect(lock["http"] == "workspace")
    #expect(try PearfyAICommand.run(arguments: ["doctor"], projectRoot: projectRoot, frameworkRoot: frameworkRoot) == 0)
}

@Test func plannedRegistryModulesAreVisibleButCannotBeInstalled() throws {
    let manager = try PearfyModuleManager()
    let payments = try manager.module(named: "payments")
    #expect(payments.available == false)
    #expect(payments.implementationStatus == .planned)
    #expect(payments.products.isEmpty)

    var rejected = false
    do {
        _ = try manager.planAdding("payments", to: ["http"])
    } catch PearfyModuleManagerError.moduleUnavailable("payments") {
        rejected = true
    }
    #expect(rejected)
}

@Test func aiInitLeavesCustomOpenCodeJSONCUntouchedAndReportsIncompleteAdapter() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-ai-jsonc-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let frameworkRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let projectRoot = root.appendingPathComponent("jsonc-api", isDirectory: true)
    _ = try ProjectScaffolder(frameworkRoot: frameworkRoot).createProject(named: "jsonc-api", at: projectRoot)
    let configURL = projectRoot.appendingPathComponent("opencode.jsonc")
    let original = "{\n  // developer config\n  \"model\": \"local/custom\"\n}\n"
    try original.write(to: configURL, atomically: true, encoding: .utf8)

    let result = try PearfyAICommand.run(
        arguments: ["init", "--client", "opencode"],
        projectRoot: projectRoot,
        frameworkRoot: frameworkRoot
    )
    #expect(result == 2)
    #expect(try String(contentsOf: configURL, encoding: .utf8) == original)
    #expect(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(".agents/skills/pearfy-core/SKILL.md").path))
}

@Test func aiSyncUpgradesLegacyModuleLocksWithoutChangingPackageProducts() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-ai-lock-upgrade-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let frameworkRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let projectRoot = root.appendingPathComponent("legacy-api", isDirectory: true)
    _ = try ProjectScaffolder(frameworkRoot: frameworkRoot).createProject(named: "legacy-api", at: projectRoot)

    let packageURL = projectRoot.appendingPathComponent("Package.swift")
    let originalPackage = try Data(contentsOf: packageURL)
    let lockURL = projectRoot.appendingPathComponent(".pearfy/modules.json")
    try #"{"formatVersion":1,"modules":["http"]}"#.write(to: lockURL, atomically: true, encoding: .utf8)
    #expect(try PearfyAICommand.run(arguments: ["sync"], projectRoot: projectRoot, frameworkRoot: frameworkRoot) == 0)

    let upgraded = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: lockURL)) as? [String: Any])
    #expect(upgraded["formatVersion"] as? Int == 2)
    #expect((upgraded["modules"] as? [String]) == ["http"])
    let versions = upgraded["moduleVersions"] as? [String: String]
    #expect(versions?["http"] == "workspace")
    #expect(try Data(contentsOf: packageURL) == originalPackage)
}

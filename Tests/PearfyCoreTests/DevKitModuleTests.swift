import Foundation
import PearfyCLIKit
import Testing

@Test func devKitUIIsOptionalAndInstallsOnlyWhenSelected() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-devkit-module-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let frameworkRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let projectRoot = root.appendingPathComponent("devkit-api", isDirectory: true)
    _ = try ProjectScaffolder(frameworkRoot: frameworkRoot).createProject(named: "devkit-api", at: projectRoot)

    let manager = try PearfyModuleManager()
    let original = try String(contentsOf: projectRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
    #expect(!original.contains("PearfyDevKitUI"))

    let plan = try manager.planAdding("devkit-ui", to: ["http"])
    #expect(plan.plannedModules == ["devkit-ui", "http"])
    #expect(Set(plan.productsToAdd) == ["PearfyDevKitUI", "PearfyObservability"])
    try manager.apply(plan, to: projectRoot)

    let updated = try String(contentsOf: projectRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
    #expect(updated.contains(".product(name: \"PearfyDevKitUI\", package: \"Pearfy\")"))
    #expect(updated.contains(".product(name: \"PearfyObservability\", package: \"Pearfy\")"))
    #expect(try manager.doctor(projectRoot: projectRoot) == ["devkit-ui", "http"])
}

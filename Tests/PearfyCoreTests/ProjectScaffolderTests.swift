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
    #expect(source.contains("__pearfy_registerRoutes"))
    #expect(source.contains("@RestController"))
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

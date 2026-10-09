import Foundation
import PearfyCLIKit
import Testing

@Test func macroPolicyDiagnosticsFindStaticRouterCallsAndIgnoreCommentsAndNonApplicationTests() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-macro-policy-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceDirectory = root.appendingPathComponent("Sources/App", isDirectory: true)
    let testsDirectory = root.appendingPathComponent("Tests/AppTests", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: testsDirectory, withIntermediateDirectories: true)
    try """
    // router.get(\"/comment\") is only documentation.
    try await appRouter.get(\"/health\") { _ in .text(\"ok\") }
    try await appRouter.on(.post, path: \"/items\") { _ in .text(\"ok\") }
    let note = \"httpRouter.delete(\" // not a route declaration
    """.write(to: sourceDirectory.appendingPathComponent("Routes.swift"), atomically: true, encoding: .utf8)
    try "try await router.get(\"/test\") { _ in .text(\"ok\") }".write(
        to: testsDirectory.appendingPathComponent("RouteTests.swift"), atomically: true, encoding: .utf8
    )

    let report = try PearfyMacroPolicyDiagnostics.check(projectRoot: root)
    #expect(report.isComplete)
    #expect(report.findings == [
        PearfyMacroPolicyFinding(path: "Sources/App/Routes.swift", line: 2, method: "get"),
        PearfyMacroPolicyFinding(path: "Sources/App/Routes.swift", line: 3, method: "post")
    ])
    #expect(report.findings.first?.guidance.contains("@Get under @RestController") == true)
    #expect(report.findings.last?.guidance.contains("@Post under @RestController") == true)
}

@Test func macroPolicyDiagnosticsReportMissingSourcesAsIncomplete() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-macro-policy-empty-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let report = try PearfyMacroPolicyDiagnostics.check(projectRoot: root)
    #expect(report.findings.isEmpty)
    #expect(!report.isComplete)
    #expect(report.skippedFiles == 1)
}

import Foundation
import PearfyCLIKit
import Testing

@Test func guardianReturnsIncompleteWhenIntegrationServicesAreNotConfigured() throws {
    let root = try makeTemporaryPackage(testSource: #"""
    import Testing
    let postgres = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_HOST"]
    let redis = ProcessInfo.processInfo.environment["PEARFY_TEST_REDIS_HOST"]
    """#)
    defer { try? FileManager.default.removeItem(at: root) }
    let executor = TestGuardianExecutor(exitCodes: [0, 0])

    let report = PearfyGuardianVerifier(executor: executor, environment: [:]).verify(projectRoot: root)

    #expect(report.status == .incomplete)
    #expect(report.gates.first(where: { $0.name == "swift-build" })?.status == .pass)
    #expect(report.gates.first(where: { $0.name == "swift-test" })?.status == .pass)
    #expect(report.gates.first(where: { $0.name == "integration-environment" })?.detail.contains("PEARFY_TEST_POSTGRES_HOST") == true)
    #expect(executor.arguments == [
        ["build", "-j", "2", "-Xswiftc", "-disable-batch-mode"],
        ["bash", "scripts/test-unit.sh", "-j", "2", "--no-parallel", "-Xswiftc", "-disable-batch-mode"]
    ])
}

@Test func guardianUsesBoundedJobOverridesFromItsEnvironment() throws {
    let root = try makeTemporaryPackage(testSource: "import Testing\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let executor = TestGuardianExecutor(exitCodes: [0, 0])

    let report = PearfyGuardianVerifier(
        executor: executor,
        environment: ["SWIFT_BUILD_JOBS": "1", "SWIFT_TEST_JOBS": "3"]
    ).verify(projectRoot: root)

    #expect(report.status == .pass)
    #expect(executor.arguments == [
        ["build", "-j", "1", "-Xswiftc", "-disable-batch-mode"],
        ["bash", "scripts/test-unit.sh", "-j", "3", "--no-parallel", "-Xswiftc", "-disable-batch-mode"]
    ])
}

@Test func guardianFailsClosedWhenARequiredBuildGateFails() throws {
    let root = try makeTemporaryPackage(testSource: "import Testing\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let executor = TestGuardianExecutor(exitCodes: [1, 0])

    let report = PearfyGuardianVerifier(executor: executor, environment: [:]).verify(projectRoot: root)

    #expect(report.status == .fail)
    #expect(report.gates.first(where: { $0.name == "swift-build" })?.status == .fail)
    #expect(report.gates.first(where: { $0.name == "integration-environment" })?.status == .pass)
}

@Test func guardianMarksNonSwiftWorkspaceIncompleteWithoutRunningCommands() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-guardian-empty-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executor = TestGuardianExecutor(exitCodes: [])

    let report = PearfyGuardianVerifier(executor: executor, environment: [:]).verify(projectRoot: root)

    #expect(report.status == .incomplete)
    #expect(report.gates.first?.name == "swift-package")
    #expect(executor.arguments.isEmpty)
}

private func makeTemporaryPackage(testSource: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-guardian-package-\(UUID().uuidString)", isDirectory: true)
    let tests = root.appendingPathComponent("Tests", isDirectory: true)
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    try Data("// test package fixture\n".utf8).write(to: root.appendingPathComponent("Package.swift"))
    try Data(testSource.utf8).write(to: tests.appendingPathComponent("FixtureTests.swift"))
    return root
}

private final class TestGuardianExecutor: GuardianCommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingExitCodes: [Int32]
    private var recordedArguments: [[String]] = []

    var arguments: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedArguments
    }

    init(exitCodes: [Int32]) {
        remainingExitCodes = exitCodes
    }

    func execute(_ command: [String], at projectRoot: URL) throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        recordedArguments.append(command)
        guard !remainingExitCodes.isEmpty else { return 99 }
        return remainingExitCodes.removeFirst()
    }
}

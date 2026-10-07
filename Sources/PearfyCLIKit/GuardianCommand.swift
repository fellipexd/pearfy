import Foundation

public enum GuardianStatus: String, Codable, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case incomplete = "INCOMPLETE"
}

public enum GuardianGateStatus: String, Codable, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case incomplete = "INCOMPLETE"
}

public struct GuardianGate: Codable, Equatable, Sendable {
    public let name: String
    public let status: GuardianGateStatus
    public let detail: String

    public init(name: String, status: GuardianGateStatus, detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
    }
}

public struct GuardianReport: Codable, Equatable, Sendable {
    public let status: GuardianStatus
    public let scope: String
    public let gates: [GuardianGate]

    public init(status: GuardianStatus, scope: String, gates: [GuardianGate]) {
        self.status = status
        self.scope = scope
        self.gates = gates
    }
}

public protocol GuardianCommandExecuting: Sendable {
    func execute(_ arguments: [String], at projectRoot: URL) throws -> Int32
}

public struct SystemGuardianCommandExecutor: GuardianCommandExecuting {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = Self.testEnvironment(from: environment)
    }

    public func execute(_ arguments: [String], at projectRoot: URL) throws -> Int32 {
        guard !arguments.isEmpty else { return 2 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments.first == "bash" ? arguments : ["swift"] + arguments
        process.currentDirectoryURL = projectRoot
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func testEnvironment(from source: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        let safeNames: Set<String> = [
            "PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT", "LANG", "LC_ALL", "CI",
            "SWIFT_EXEC", "CC", "CXX", "PKG_CONFIG_PATH", "SWIFT_BUILD_JOBS", "SWIFT_TEST_JOBS"
        ]
        for name in safeNames {
            if let value = source[name] { result[name] = value }
        }
        for name in ["SWIFT_BUILD_JOBS", "SWIFT_TEST_JOBS"] {
            if let value = result[name], let jobs = Int(value), (1...8).contains(jobs) {
                result[name] = String(jobs)
            } else {
                result.removeValue(forKey: name)
            }
        }
        // Pearfy integration tests may need dedicated test-database credentials.
        // Application/provider secrets, including cloud AI credentials, are not
        // forwarded to the build/test subprocess.
        for (name, value) in source where name.hasPrefix("PEARFY_TEST_") {
            result[name] = value
        }
        return result
    }
}

public struct PearfyGuardianVerifier: Sendable {
    private let executor: any GuardianCommandExecuting
    private let environment: [String: String]

    public init(
        executor: any GuardianCommandExecuting = SystemGuardianCommandExecutor(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executor = executor
        self.environment = environment
    }

    public func verify(projectRoot: URL) -> GuardianReport {
        let root = projectRoot.standardizedFileURL
        let manifest = root.appendingPathComponent("Package.swift")
        let tests = root.appendingPathComponent("Tests", isDirectory: true)
        guard FileManager.default.fileExists(atPath: manifest.path),
              FileManager.default.fileExists(atPath: tests.path) else {
            return GuardianReport(
                status: .incomplete,
                scope: Self.scope,
                gates: [GuardianGate(
                    name: "swift-package",
                    status: .incomplete,
                    detail: "Package.swift and Tests/ are both required for this verification profile"
                )]
            )
        }

        let integrationVariables: [String]
        do {
            integrationVariables = try Self.integrationEnvironmentVariables(in: tests)
        } catch {
            return GuardianReport(
                status: .incomplete,
                scope: Self.scope,
                gates: [GuardianGate(
                    name: "test-inventory",
                    status: .incomplete,
                    detail: "could not inspect test sources"
                )]
            )
        }

        var gates: [GuardianGate] = []
        let buildJobs = Self.jobLimit(environment["SWIFT_BUILD_JOBS"])
        let testJobs = Self.jobLimit(environment["SWIFT_TEST_JOBS"])
        for (name, arguments) in [
            ("swift-build", ["build", "-j", String(buildJobs), "-Xswiftc", "-disable-batch-mode"]),
            ("swift-test", ["bash", "scripts/test-unit.sh", "-j", String(testJobs), "--no-parallel", "-Xswiftc", "-disable-batch-mode"])
        ] {
            do {
                let exitCode = try executor.execute(arguments, at: root)
                gates.append(GuardianGate(
                    name: name,
                    status: exitCode == 0 ? .pass : .fail,
                    detail: exitCode == 0 ? "command exited successfully" : "command exited with status \(exitCode)"
                ))
            } catch {
                gates.append(GuardianGate(
                    name: name,
                    status: .incomplete,
                    detail: "command could not be started"
                ))
            }
        }

        let missing = integrationVariables.filter { environment[$0]?.isEmpty != false }
        if integrationVariables.isEmpty {
            gates.append(GuardianGate(
                name: "integration-environment",
                status: .pass,
                detail: "no test-declared external service gates found"
            ))
        } else if missing.isEmpty {
            gates.append(GuardianGate(
                name: "integration-environment",
                status: .pass,
                detail: "all test-declared external service variables are configured"
            ))
        } else {
            gates.append(GuardianGate(
                name: "integration-environment",
                status: .incomplete,
                detail: "missing required test environment variables: \(missing.joined(separator: ", "))"
            ))
        }

        let status: GuardianStatus
        if gates.contains(where: { $0.status == .fail }) {
            status = .fail
        } else if gates.contains(where: { $0.status == .incomplete }) {
            status = .incomplete
        } else {
            status = .pass
        }
        return GuardianReport(status: status, scope: Self.scope, gates: gates)
    }

    public static let scope = "Swift build, Swift tests, and test-declared service environment; not a full security/contract/data certification"

    private static func jobLimit(_ raw: String?) -> Int {
        guard let raw, let value = Int(raw), (1...8).contains(value) else { return 2 }
        return value
    }

    private static func integrationEnvironmentVariables(in testsRoot: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: testsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw GuardianInventoryError.unreadableTests
        }

        var variables = Set<String>()
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let contents = try String(contentsOf: file, encoding: .utf8)
            var cursor = contents.startIndex
            while let marker = contents.range(of: "PEARFY_TEST_", range: cursor..<contents.endIndex) {
                var end = marker.lowerBound
                while end < contents.endIndex {
                    let byte = contents[end].utf8.first ?? 0
                    guard (65...90).contains(byte) || (48...57).contains(byte) || byte == 95 else { break }
                    contents.formIndex(after: &end)
                }
                let name = String(contents[marker.lowerBound..<end])
                if name.hasSuffix("_HOST") { variables.insert(name) }
                cursor = end == marker.lowerBound ? contents.index(after: marker.lowerBound) : end
            }
        }
        return variables.sorted()
    }
}

public enum PearfyGuardianCommand {
    public static func run(arguments: [String], projectRoot: URL) throws -> Int32 {
        guard arguments == ["verify"] else { throw GuardianCommandError.usage }
        let report = PearfyGuardianVerifier().verify(projectRoot: projectRoot)
        for gate in report.gates {
            print("\(gate.status.rawValue) \(gate.name): \(gate.detail)")
        }
        print("Guardian \(report.status.rawValue): \(report.scope)")
        return switch report.status {
        case .pass: 0
        case .fail: 1
        case .incomplete: 2
        }
    }
}

public enum GuardianCommandError: Error, Sendable, Equatable, CustomStringConvertible {
    case usage

    public var description: String {
        switch self {
        case .usage: "Usage: pearfy guardian verify"
        }
    }
}

private enum GuardianInventoryError: Error {
    case unreadableTests
}

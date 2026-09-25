import Foundation

public enum ProjectScaffoldError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidName(String)
    case destinationExists(String)
    case invalidFrameworkPath(String)

    public var description: String {
        switch self {
        case .invalidName(let name):
            "Invalid project name '\(name)'. Use letters, numbers, and hyphens; start with a letter."
        case .destinationExists(let path):
            "Destination already exists: \(path)"
        case .invalidFrameworkPath(let path):
            "No Pearfy Package.swift found at framework path: \(path)"
        }
    }
}

/// Generates a small executable Swift package linked to a local Pearfy checkout.
public struct ProjectScaffolder: Sendable {
    public let frameworkRoot: URL

    public init(frameworkRoot: URL) {
        self.frameworkRoot = frameworkRoot.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func createProject(named name: String, at destination: URL) throws -> URL {
        guard Self.isValidProjectName(name) else {
            throw ProjectScaffoldError.invalidName(name)
        }
        guard FileManager.default.fileExists(atPath: frameworkRoot.appendingPathComponent("Package.swift").path) else {
            throw ProjectScaffoldError.invalidFrameworkPath(frameworkRoot.path)
        }

        let output = destination.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ProjectScaffoldError.destinationExists(output.path)
        }

        let moduleName = Self.moduleName(from: name)
        let pearfyPath = frameworkRoot.path
        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).pearfy-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: temporary.appendingPathComponent("Sources/\(moduleName)", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: temporary.appendingPathComponent(".pearfy", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Self.packageManifest(name: name, moduleName: moduleName, pearfyPath: pearfyPath)
                .write(to: temporary.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try PearfyModuleManager()
                .initialLockfileData()
                .write(to: temporary.appendingPathComponent(".pearfy/modules.json"), options: .atomic)
            try Self.applicationSource(moduleName: moduleName)
                .write(to: temporary.appendingPathComponent("Sources/\(moduleName)/main.swift"), atomically: true, encoding: .utf8)
            try Self.readme(name: name, moduleName: moduleName)
                .write(to: temporary.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try """
            .build/
            .swiftpm/
            .DS_Store
            """.write(to: temporary.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            try FileManager.default.moveItem(at: temporary, to: output)
            return output
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public static func frameworkRootFromSourceFile(_ sourceFile: String) -> URL {
        URL(fileURLWithPath: sourceFile)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    private static func isValidProjectName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func moduleName(from projectName: String) -> String {
        projectName.split(separator: "-").map { part in
            part.prefix(1).uppercased() + part.dropFirst()
        }.joined()
    }

    private static func packageManifest(name: String, moduleName: String, pearfyPath: String) -> String {
        """
        // swift-tools-version: 6.2
        import PackageDescription

        let package = Package(
            name: "\(swiftLiteral(name))",
            platforms: [.macOS(.v13)],
            dependencies: [
                .package(name: "Pearfy", path: "\(swiftLiteral(pearfyPath))")
            ],
            targets: [
                .executableTarget(
                    name: "\(moduleName)",
                    dependencies: [
                        // pearfy-modules:begin
                        .product(name: "PearfyConfiguration", package: "Pearfy"),
                        .product(name: "PearfyContext", package: "Pearfy"),
                        .product(name: "PearfyMacros", package: "Pearfy"),
                        .product(name: "PearfyNIO", package: "Pearfy"),
                        .product(name: "PearfyValidation", package: "Pearfy"),
                        .product(name: "PearfyWeb", package: "Pearfy"),
                        // pearfy-modules:end
                    ],
                    plugins: [.plugin(name: "PearfyDiscoveryPlugin", package: "Pearfy")]
                )
            ]
        )
        """
    }

    private static func applicationSource(moduleName: String) -> String {
        """
        import PearfyConfiguration
        import PearfyContext
        import PearfyMacros
        import PearfyNIO
        import PearfyValidation
        import PearfyWeb

        @RestController("/hello")
        @PermitAll
        struct GreetingController: Sendable {
            @Get("/{name}")
            func greeting(@PathVariable name: String) -> String {
                "Hello, \\(name)!"
            }
        }

        @main
        struct \(moduleName) {
            static func main() async throws {
                let configuration = try ConfigurationLoader.load(
                    defaults: ["http.host": "127.0.0.1", "http.port": "8080"]
                )
                let host = try configuration.string(forKey: "http.host")
                let port = try configuration.value(forKey: "http.port", as: Int.self)
                let router = HTTPRouter()
                try await GreetingController.__pearfy_registerRoutes(in: router, instance: GreetingController())
                let server = PearfyHTTPServer(router: router, host: host, port: port)
                let context = ApplicationContext(
                    configuration: configuration,
                    lifecycle: [server]
                )
                try await context.start()
                print("Listening on http://\\(host):\\(await server.boundPort() ?? port)")
                await PearfyProcessSignals.waitForTermination()
                try await context.stop()
            }
        }
        """
    }

    private static func readme(name: String, moduleName: String) -> String {
        """
        # \(name)

        A Pearfy HTTP application scaffold. Its route registration is generated from the controller macros.

        ```bash
        swift build
        swift run \(moduleName)
        curl http://127.0.0.1:8080/hello/pear
        # stop gracefully with Ctrl+C or SIGTERM
        ```

        Optional Pearfy products can be planned/installed with `pearfy modules list`, `pearfy modules plan --add postgres`, and `pearfy add postgres`. Run `pearfy modules doctor` to verify the generated dependency lock and manifest.

        This scaffold links to the local Pearfy checkout using its current absolute path. If the checkout moves, update the Pearfy path in `Package.swift`. Set `PEARFY_HTTP_PORT` to choose another listening port.
        """
    }

    private static func swiftLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

import Foundation

/// Build and run commands for the Swift package in the current directory.
public enum PearfyApplicationCommand {
    public static func run(
        _ action: String,
        arguments: [String],
        projectRoot: URL
    ) throws -> Int32 {
        guard ["dev", "start", "build"].contains(action) else {
            throw PearfyApplicationCommandError.usage
        }
        guard FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("Package.swift").path) else {
            throw PearfyApplicationCommandError.packageManifestNotFound(projectRoot.path)
        }

        let options = try Options(arguments: arguments, action: action)
        let configuration = options.configuration ?? (action == "dev" ? "debug" : "release")
        let swiftArguments = swiftPMArguments(
            action: action == "dev" ? "start" : action,
            configuration: configuration,
            product: options.product,
            applicationArguments: options.applicationArguments
        )

        if action == "dev" {
            guard let watchexec = executable(named: "watchexec") else {
                throw PearfyApplicationCommandError.watchexecRequired
            }
            let watchedPaths = try watchPaths(projectRoot: projectRoot)
            var watcherArguments = ["--restart"]
            for path in watchedPaths {
                watcherArguments += ["--watch", path.path]
            }
            watcherArguments += ["--ignore", ".build", "--ignore", ".swiftpm", "--ignore", ".git", "--"]
            watcherArguments += ["swift"] + swiftArguments
            return try execute(watchexec, arguments: watcherArguments, at: projectRoot)
        }

        return try execute("swift", arguments: swiftArguments, at: projectRoot)
    }

    private struct Options {
        let product: String?
        let configuration: String?
        let applicationArguments: [String]

        init(arguments: [String], action: String) throws {
            var product: String?
            var configuration: String?
            var appArguments: [String] = []
            var seen: Set<String> = []
            var index = 0

            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--" {
                    appArguments = Array(arguments.dropFirst(index + 1))
                    break
                }
                guard ["--product", "--configuration"].contains(argument) else {
                    throw PearfyApplicationCommandError.unknownOption(argument)
                }
                guard seen.insert(argument).inserted else {
                    throw PearfyApplicationCommandError.duplicateOption(argument)
                }
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw PearfyApplicationCommandError.missingValue(argument)
                }
                let value = arguments[index + 1]
                switch argument {
                case "--product":
                    product = value
                case "--configuration":
                    guard ["debug", "release"].contains(value) else {
                        throw PearfyApplicationCommandError.invalidConfiguration(value)
                    }
                    configuration = value
                default:
                    break
                }
                index += 2
            }

            if action == "build", !appArguments.isEmpty {
                throw PearfyApplicationCommandError.buildDoesNotAcceptApplicationArguments
            }
            self.product = product
            self.configuration = configuration
            self.applicationArguments = appArguments
        }
    }

    private static func swiftPMArguments(
        action: String,
        configuration: String,
        product: String?,
        applicationArguments: [String]
    ) -> [String] {
        let swiftPMAction = action == "start" ? "run" : action
        var arguments = [swiftPMAction, "--configuration", configuration]
        if let product { arguments += ["--product", product] }
        if swiftPMAction == "run", !applicationArguments.isEmpty {
            arguments.append("--")
            arguments += applicationArguments
        }
        return arguments
    }

    private static func watchPaths(projectRoot: URL) throws -> [URL] {
        let root = projectRoot.standardizedFileURL
        var candidates = sourceWatchPaths(in: root)
        let dependencies = try pearfyDependencyPaths(projectRoot: root)
        for dependency in dependencies {
            candidates += sourceWatchPaths(in: dependency)
        }
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func sourceWatchPaths(in root: URL) -> [URL] {
        let manager = FileManager.default
        var paths = ["Package.swift", "Package.resolved"].map { root.appendingPathComponent($0) }
        for directory in ["Sources", "Plugins"] {
            let url = root.appendingPathComponent(directory, isDirectory: true)
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                paths.append(url)
            }
        }
        return paths.filter { manager.fileExists(atPath: $0.path) }
    }

    private struct DependencyGraph: Decodable {
        let name: String
        let path: String?
        let dependencies: [DependencyGraph]
    }

    private static func pearfyDependencyPaths(projectRoot: URL) throws -> [URL] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "package", "show-dependencies", "--format", "json"]
        process.currentDirectoryURL = projectRoot
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PearfyApplicationCommandError.dependencyGraphUnavailable
        }
        let graph = try JSONDecoder().decode(DependencyGraph.self, from: data)
        var paths: [URL] = []
        func collect(_ node: DependencyGraph) {
            if node.name == "Pearfy", let path = node.path {
                paths.append(URL(fileURLWithPath: path).standardizedFileURL)
            }
            node.dependencies.forEach(collect)
        }
        collect(graph)
        return paths
    }

    private static func executable(named name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func execute(_ executable: String, arguments: [String], at root: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private enum PearfyApplicationCommandError: Error, CustomStringConvertible {
    case usage
    case packageManifestNotFound(String)
    case unknownOption(String)
    case duplicateOption(String)
    case missingValue(String)
    case invalidConfiguration(String)
    case buildDoesNotAcceptApplicationArguments
    case watchexecRequired
    case dependencyGraphUnavailable

    var description: String {
        switch self {
        case .usage:
            "Usage: pearfy <dev|start|build> [--product <name>] [--configuration <debug|release>] [-- <app-arguments>]"
        case .packageManifestNotFound(let path):
            "Package.swift not found in \(path); run this command from a Swift package root"
        case .unknownOption(let option): "unknown option: \(option)"
        case .duplicateOption(let option): "option provided more than once: \(option)"
        case .missingValue(let option): "missing value for \(option)"
        case .invalidConfiguration(let value): "invalid configuration \(value); use debug or release"
        case .buildDoesNotAcceptApplicationArguments:
            "build does not accept application arguments"
        case .watchexecRequired:
            "`pearfy dev` requires watchexec; install it with `brew install watchexec` or your system package manager"
        case .dependencyGraphUnavailable:
            "could not inspect Swift package dependencies for dev watch paths"
        }
    }
}

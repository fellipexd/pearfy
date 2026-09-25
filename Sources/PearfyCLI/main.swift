import Foundation
import PearfyCLIKit

@main
struct PearfyCLI {
    static func main() {
        do {
            let status = try run(Array(CommandLine.arguments.dropFirst()))
            if status != 0 { exit(status) }
        } catch {
            FileHandle.standardError.write(Data("pearfy: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run(_ arguments: [String]) throws -> Int32 {
        guard let command = arguments.first, command != "--help", command != "-h" else {
            print(usage)
            return 0
        }
        if command == "benchmark" {
            return try PearfyPerformanceCommand.benchmark(
                frameworkRoot: frameworkRoot,
                arguments: Array(arguments.dropFirst())
            )
        }
        if command == "doctor" {
            guard arguments.dropFirst().first == "performance" else { throw CLIError.unknownCommand("doctor") }
            return PearfyPerformanceCommand.doctorPerformance(frameworkRoot: frameworkRoot)
        }
        if command == "profile" {
            guard arguments.count >= 2 else { throw PerformanceCommandError.usage }
            return try PearfyPerformanceCommand.profile(kind: arguments[1], arguments: Array(arguments.dropFirst(2)))
        }
        guard command == "new" else { throw CLIError.unknownCommand(command) }
        guard arguments.count >= 2 else {
            throw CLIError.usage
        }

        let projectName = arguments[1]
        var destination: URL?
        var frameworkRoot: URL?
        var index = 2
        while index < arguments.count {
            let flag = arguments[index]
            guard index + 1 < arguments.count else { throw CLIError.missingValue(flag) }
            let value = arguments[index + 1]
            switch flag {
            case "--path":
                guard destination == nil else { throw CLIError.duplicateOption(flag) }
                destination = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            case "--framework-path":
                guard frameworkRoot == nil else { throw CLIError.duplicateOption(flag) }
                frameworkRoot = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            default:
                throw CLIError.unknownOption(flag)
            }
            index += 2
        }

        let defaultFrameworkRoot = ProjectScaffolder.frameworkRootFromSourceFile(#filePath)
        let frameworkURL = frameworkRoot
            ?? ProcessInfo.processInfo.environment["PEARFY_FRAMEWORK_PATH"].map {
                URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            }
            ?? defaultFrameworkRoot
        let output = destination ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(projectName, isDirectory: true)
        let created = try ProjectScaffolder(frameworkRoot: frameworkURL)
            .createProject(named: projectName, at: output)
        print("Created \(projectName) at \(created.path)")
        print("Next: cd \(created.path) && swift run \(moduleName(from: projectName))")
        return 0
    }

    private static var frameworkRoot: URL {
        if let path = ProcessInfo.processInfo.environment["PEARFY_FRAMEWORK_PATH"] {
            return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        }
        return ProjectScaffolder.frameworkRootFromSourceFile(#filePath)
    }

    private static func moduleName(from name: String) -> String {
        name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    private static let usage = """
    Pearfy CLI

    Usage:
      pearfy new <project-name> [--path <directory>] [--framework-path <directory>]
      pearfy benchmark [benchmark options]
      pearfy profile <cpu|memory> -- <program> [arguments...]
      pearfy doctor performance
      pearfy --help

    `new` creates an executable package linked to a local Pearfy checkout.
    `benchmark` runs the DI baseline tool; profiling uses host-native tools.
    Set PEARFY_FRAMEWORK_PATH or pass --framework-path when using a relocated CLI.
    """
}

private enum CLIError: Error, CustomStringConvertible {
    case usage
    case missingValue(String)
    case duplicateOption(String)
    case unknownOption(String)
    case unknownCommand(String)

    var description: String {
        switch self {
        case .usage: "Usage: pearfy new <project-name> [--path <directory>] [--framework-path <directory>]"
        case .missingValue(let option): "missing value for \(option)"
        case .duplicateOption(let option): "option provided more than once: \(option)"
        case .unknownOption(let option): "unknown option: \(option)"
        case .unknownCommand(let command): "unknown command: \(command). Try `pearfy --help`."
        }
    }
}

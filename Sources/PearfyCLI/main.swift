import Foundation
import PearfyCLIKit
import PearfyPopulateCLI

@main
struct PearfyCLI {
    static func main() async {
        do {
            let status = try await run(Array(CommandLine.arguments.dropFirst()))
            if status != 0 { exit(status) }
        } catch {
            FileHandle.standardError.write(Data("pearfy: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run(_ arguments: [String]) async throws -> Int32 {
        guard let command = arguments.first, command != "--help", command != "-h" else {
            print(usage)
            return 0
        }
        if command == "--version" || command == "-V" {
            print("Pearfy Framework \(PearfyProjectLifecycleCommand.frameworkVersion); Pearfy CLI \(PearfyProjectLifecycleCommand.cliVersion)")
            return 0
        }
        if command == "benchmark" {
            return try PearfyPerformanceCommand.benchmark(
                frameworkRoot: frameworkRoot,
                arguments: Array(arguments.dropFirst())
            )
        }
        if command == "doctor" {
            if arguments.dropFirst().first == "performance" {
                return PearfyPerformanceCommand.doctorPerformance(frameworkRoot: frameworkRoot)
            }
            return try await PearfyProjectLifecycleCommand.run(
                command: command,
                arguments: Array(arguments.dropFirst()),
                projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                frameworkRoot: frameworkRoot
            )
        }
        if command == "guardian" {
            return try PearfyGuardianCommand.run(
                arguments: Array(arguments.dropFirst()),
                projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            )
        }
        if command == "populate" {
            return try await PearfyPopulateCommand.run(
                arguments: Array(arguments.dropFirst()),
                projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            )
        }
        if command == "gameserver" {
            return try PearfyGameServerCommand.run(Array(arguments.dropFirst()))
        }
        if command == "migrations" {
            return try await PearfyMigrationsCommand.run(
                arguments: Array(arguments.dropFirst()),
                projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            )
        }
        if ["init", "adopt", "migrate", "baseline", "inspect", "sync", "architecture"].contains(command) {
            return try await PearfyProjectLifecycleCommand.run(
                command: command,
                arguments: Array(arguments.dropFirst()),
                projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                frameworkRoot: frameworkRoot
            )
        }
        if command == "ai" {
            return try PearfyAICommand.run(
                arguments: Array(arguments.dropFirst()),
                projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                frameworkRoot: frameworkRoot
            )
        }
        if command == "sdk" {
            return try PearfySDKVersionCommand.run(Array(arguments.dropFirst()))
        }
        if command == "devkit" {
            return try await PearfyDevKitCLICommand.run(
                Array(arguments.dropFirst()),
                projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            )
        }
        if command == "profile" {
            guard arguments.count >= 2 else { throw PerformanceCommandError.usage }
            return try PearfyPerformanceCommand.profile(kind: arguments[1], arguments: Array(arguments.dropFirst(2)))
        }
        if command == "mcp" {
            guard arguments.count == 1 else { throw CLIError.usage }
            return try PearfyMCPCommand.run(
                projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            )
        }
        if command == "modules" {
            return try PearfyModuleCommand.run(
                Array(arguments.dropFirst()),
                projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            )
        }
        if command == "add" || command == "remove" {
            guard arguments.count == 2 || (arguments.count == 3 && arguments[2] == "--dry-run") else {
                throw CLIError.usage
            }
            let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let status = try PearfyModuleCommand.modify(
                command,
                module: arguments[1],
                projectRoot: projectRoot,
                dryRun: arguments.count == 3
            )
            if status == 0, arguments.count == 2 {
                return try PearfyAICommand.syncAfterModuleChange(projectRoot: projectRoot, frameworkRoot: frameworkRoot)
            }
            return status
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
        let output = (destination ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(projectName, isDirectory: true)).standardizedFileURL
        return try await PearfyProjectLifecycleCommand.run(
            command: "init",
            arguments: [projectName, "--path", output.path],
            projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            frameworkRoot: frameworkURL
        )
    }

    private static var frameworkRoot: URL {
        if let path = ProcessInfo.processInfo.environment["PEARFY_FRAMEWORK_PATH"] {
            return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        }
        return ProjectScaffolder.frameworkRootFromSourceFile(#filePath)
    }

    private static let usage = """
    Pearfy CLI

    Usage:
      pearfy new <project-name> [--path <directory>] [--framework-path <directory>]
      pearfy init <project-name> [--profile <profile>] [--path <directory>] [--decision <key=value>]
      pearfy adopt [--path <directory>] [--name <project-name>] [--profile <profile>]
      pearfy migrate [--framework <id>] [--profile <profile>]
      pearfy migrate <status|domain|route|element|verify|curl|finalize> [options]
      pearfy baseline [--framework <id>] [--profile <profile>]
      pearfy inspect [--path <directory>] [--framework <id>]
      pearfy sync [--apply] [--path <directory>]
      pearfy doctor [--path <directory>]
      pearfy architecture check
      pearfy modules <list|info <id>|doctor|plan --add|--remove <id>>
      pearfy <add|remove> <module-id> [--dry-run]
      pearfy mcp
      pearfy benchmark [benchmark options]
      pearfy profile <cpu|memory> -- <program> [arguments...]
      pearfy doctor performance
      pearfy guardian verify
      pearfy --version
      pearfy populate <inspect|profile|plan|preview|approve|run|status|verify|report> [options]
      pearfy gameserver <modules|modes|template --mode <light|medium|high> [--output <file>]|recipe <turn-based|fps|friendslop|mmo|rooms|dedicated> [--output <file>]|recovery --store redis [--apply] [--output <file>]>
      pearfy migrations <generate|apply|import-java> [options]
      pearfy ai init [--client opencode]
      pearfy ai sync [--force]
      pearfy ai inspect [--module <id>|--scenarios]
      pearfy ai doctor
      pearfy ai mcp <list|enable|disable <module>>
      pearfy sdk versions
      pearfy devkit <start|open|doctor|export> [options]
      pearfy --help

    `new` creates an executable package linked to a local Pearfy checkout.
    `init` creates a versioned traceability manifest and architecture profile.
    `inspect` is read-only; `baseline`, `adopt`, and `migrate` record evidence and the canonical Legacy Contract.
    `migrate verify` compares selected legacy/Pearfy HTTP contracts; writes require sandbox opt-in.
    `modules` lists available products and checks a generated project's selection.
    `guardian verify` executes the declared Swift build/test gates for the current package.
    `populate` plans and executes bounded synthetic PostgreSQL data runs.
    `gameserver template` prints a starter profile as JSON; `--output` writes without replacing a file.
    `gameserver recipe` prints a genre/server composition plan and application-owned validation gates.
    `gameserver recovery` prints a secret-free Redis recovery plan; `--apply` selects the optional module and writes its config.
    `migrations generate` compiles a Pearfy SchemaIR model into an immutable SQL artifact; `apply` runs the catalog locally.
    `ai` initializes a Skills-first harness and synchronizes only installed module Skills.
    `ai mcp` enables dynamic tools only for an installed module that implements them.
    `sdk versions` lists the v1.6 through v1.8 capability milestones in this checkout.
    `devkit` opens, checks, or exports data from an installed local DevKit dashboard.
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
        case .usage: "Usage: pearfy new <project-name> [--path <directory>] [--framework-path <directory>] | pearfy modules <list|info|doctor|plan> | pearfy <add|remove> <module-id> [--dry-run]"
        case .missingValue(let option): "missing value for \(option)"
        case .duplicateOption(let option): "option provided more than once: \(option)"
        case .unknownOption(let option): "unknown option: \(option)"
        case .unknownCommand(let command): "unknown command: \(command). Try `pearfy --help`."
        }
    }
}

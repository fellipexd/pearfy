import Foundation
import PearfyGameServer

public enum PearfyGameServerCommand {
    public static func run(_ arguments: [String], currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> Int32 {
        guard let subcommand = arguments.first else { throw GameServerCLIError.usage }
        switch subcommand {
        case "modules":
            guard arguments.count == 1 else { throw GameServerCLIError.usage }
            let registry = try PearfyModuleManager()
            for module in registry.catalogModules().filter({ $0.id == "gameserver" || $0.id.hasPrefix("gameserver-") }) {
                let availability = module.available ? "available" : "planned"
                let products = module.products.isEmpty ? "—" : module.products.joined(separator: ",")
                print("\(module.id)\t\(module.implementationStatus.rawValue)\t\(availability)\t\(products)\t\(module.summary)")
            }
        case "modes":
            guard arguments.count == 1 else { throw GameServerCLIError.usage }
            print("light   gRPC/TLS + WebSocket/TLS, JSON, Swift ARC; 20Hz, up to 128 inputs/tick; closes admission after 3 consecutive overruns")
            print("medium  gRPC/TLS + WebSocket/TLS, JSON, ownership-oriented buffers with ARC; 30Hz, up to 1,024 inputs/tick; closes admission after 3 consecutive overruns")
            print("high    gRPC/TLS + target UDP/binary, ownership-oriented buffers with ARC; 60Hz, up to 8,192 inputs/tick; closes admission after 3 consecutive overruns; UDP stays disabled until app key provisioning and socket/abuse validation pass")
        case "recipe":
            guard arguments.count >= 2,
                  let recipe = GameServerRecipe(rawValue: arguments[1]) else { throw GameServerCLIError.usage }
            var output: URL?
            var index = 2
            while index < arguments.count {
                guard arguments[index] == "--output", index + 1 < arguments.count else { throw GameServerCLIError.usage }
                guard output == nil else { throw GameServerCLIError.duplicateOption("--output") }
                output = URL(fileURLWithPath: arguments[index + 1], relativeTo: currentDirectory).standardizedFileURL
                index += 2
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(GameServerRecipeProfile.preset(recipe))
            try emit(data, to: output, label: "\(recipe.rawValue) gameserver recipe")
            if GameServerRecipeProfile.preset(recipe).mode == .high {
                FileHandle.standardError.write(Data("warning: high mode is an unbenchmarked target; UDP remains disabled until app key provisioning and socket/abuse validation pass.\n".utf8))
            }
        case "recovery":
            guard arguments.count >= 3, arguments[1] == "--store", arguments[2] == "redis" else {
                throw GameServerCLIError.usage
            }
            var apply = false
            var output: URL?
            var index = 3
            while index < arguments.count {
                switch arguments[index] {
                case "--apply":
                    guard !apply else { throw GameServerCLIError.duplicateOption("--apply") }
                    apply = true
                    index += 1
                case "--output":
                    guard output == nil, index + 1 < arguments.count else {
                        throw output == nil ? GameServerCLIError.usage : GameServerCLIError.duplicateOption("--output")
                    }
                    output = URL(fileURLWithPath: arguments[index + 1], relativeTo: currentDirectory).standardizedFileURL
                    index += 2
                default:
                    throw GameServerCLIError.usage
                }
            }

            let manager = try PearfyModuleManager()
            let selected = try manager.doctor(projectRoot: currentDirectory)
            let resolved = try manager.resolvedModuleIDs(projectRoot: currentDirectory)
            guard resolved.contains("gameserver"), resolved.contains("redis") else {
                throw GameServerCLIError.recoveryPrerequisites
            }
            let modulePlan = try manager.planAdding("gameserver-redis-recovery", to: selected)
            let configURL = output ?? currentDirectory.appendingPathComponent(".pearfy/gameserver-recovery.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let configuration = try encoder.encode(GameServerRecoveryProfile.redis) + Data([0x0a])

            guard apply else {
                let plan = GameServerRecoveryCommandPlan(
                    store: "redis",
                    currentModules: modulePlan.currentModules,
                    plannedModules: modulePlan.plannedModules,
                    productsToAdd: modulePlan.productsToAdd,
                    configurationPath: configURL.path,
                    configuration: GameServerRecoveryProfile.redis,
                    applied: false
                )
                FileHandle.standardOutput.write(try encoder.encode(plan))
                FileHandle.standardOutput.write(Data([0x0a]))
                return 0
            }

            guard !FileManager.default.fileExists(atPath: configURL.path) else {
                throw GameServerCLIError.outputExists(configURL.path)
            }
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let alreadySelected = selected.contains("gameserver-redis-recovery")
            if !alreadySelected { try manager.apply(modulePlan, to: currentDirectory) }
            do {
                // Foundation's exclusive-create option cannot be combined with atomic
                // replacement; withoutOverwriting still protects a concurrent creator.
                try configuration.write(to: configURL, options: [.withoutOverwriting])
            } catch {
                if !alreadySelected,
                   let rollback = try? manager.planRemoving("gameserver-redis-recovery", from: modulePlan.plannedModules) {
                    try? manager.apply(rollback, to: currentDirectory)
                }
                throw error
            }
            print("Selected gameserver-redis-recovery and wrote secret-free Redis recovery configuration to \(configURL.path)")
        case "template":
            guard arguments.count >= 3, arguments[1] == "--mode",
                  let mode = GameServerMode(rawValue: arguments[2]) else { throw GameServerCLIError.usage }
            var output: URL?
            var index = 3
            while index < arguments.count {
                guard arguments[index] == "--output", index + 1 < arguments.count else { throw GameServerCLIError.usage }
                guard output == nil else { throw GameServerCLIError.duplicateOption("--output") }
                output = URL(fileURLWithPath: arguments[index + 1], relativeTo: currentDirectory).standardizedFileURL
                index += 2
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(GameServerModeProfile.preset(mode))
            if let output {
                do {
                    try data.write(to: output, options: [.withoutOverwriting])
                } catch CocoaError.fileWriteFileExists {
                    throw GameServerCLIError.outputExists(output.path)
                }
                print("Wrote \(mode.rawValue) gameserver starter template to \(output.path)")
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            if mode == .high {
                FileHandle.standardError.write(Data("warning: high targets binary UDP; the client/server codecs interoperate, but UDP stays disabled until the app provisions session keys and validates the full socket and overload/abuse path.\n".utf8))
            }
        default:
            throw GameServerCLIError.usage
        }
        return 0
    }

    private static func emit(_ data: Data, to output: URL?, label: String) throws {
        if let output {
            do {
                try data.write(to: output, options: [.withoutOverwriting])
            } catch CocoaError.fileWriteFileExists {
                throw GameServerCLIError.outputExists(output.path)
            }
            print("Wrote \(label) to \(output.path)")
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}

private enum GameServerCLIError: Error, CustomStringConvertible {
    case usage
    case duplicateOption(String)
    case outputExists(String)
    case recoveryPrerequisites

    var description: String {
        switch self {
        case .usage: "Usage: pearfy gameserver <modules|modes|template --mode <light|medium|high> [--output <file>]|recipe <turn-based|fps|friendslop|mmo|rooms|dedicated> [--output <file>]|recovery --store redis [--apply] [--output <file>] >"
        case .duplicateOption(let option): "gameserver command accepts \(option) only once"
        case .outputExists(let path): "gameserver command will not overwrite existing file: \(path)"
        case .recoveryPrerequisites: "Redis recovery requires a managed project with gameserver and redis selected; no project changes were made"
        }
    }
}

private struct GameServerRecoveryCommandPlan: Codable {
    let store: String
    let currentModules: [String]
    let plannedModules: [String]
    let productsToAdd: [String]
    let configurationPath: String
    let configuration: GameServerRecoveryProfile
    let applied: Bool
}

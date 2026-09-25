import Foundation

public struct PearfyModuleManifest: Codable, Equatable, Sendable {
    public let id: String
    public let summary: String
    public let requirements: [String]
    public let products: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case summary
        case requirements = "requires"
        case products
    }
}

public struct PearfyModulePlan: Equatable, Sendable {
    public let action: String
    public let module: String
    public let currentModules: [String]
    public let plannedModules: [String]
    public let productsToAdd: [String]
    public let productsToRemove: [String]
}

public enum PearfyModuleManagerError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidRegistry(String)
    case unknownModule(String)
    case moduleNotSelected(String)
    case requiredModule(String, by: [String])
    case requiredBaseModule(String)
    case managedProjectRequired
    case invalidLockfile
    case stalePlan
    case packageDrift

    public var description: String {
        switch self {
        case .invalidRegistry(let detail): "PEARFY_MODULE_001: invalid module registry: \(detail)"
        case .unknownModule(let id): "PEARFY_MODULE_002: module '\(id)' is not available in this checkout"
        case .moduleNotSelected(let id): "PEARFY_MODULE_003: module '\(id)' is not selected in this project"
        case .requiredModule(let id, let dependents):
            "PEARFY_MODULE_004: module '\(id)' is required by \(dependents.joined(separator: ", "))"
        case .requiredBaseModule(let id): "PEARFY_MODULE_005: base module '\(id)' cannot be removed"
        case .managedProjectRequired: "PEARFY_MODULE_006: project has no Pearfy module-manager markers; no files were changed"
        case .invalidLockfile: "PEARFY_MODULE_007: .pearfy/modules.json is missing or invalid"
        case .stalePlan: "PEARFY_MODULE_008: project modules changed after this plan was created"
        case .packageDrift: "PEARFY_MODULE_009: Package.swift does not match the Pearfy module lock"
        }
    }
}

/// Resolves and applies only products present in this checkout's module
/// registry. Package edits are restricted to marker-managed Pearfy scaffolds.
public struct PearfyModuleManager: Sendable {
    private struct RegistryFile: Decodable {
        let schemaVersion: Int
        let modules: [PearfyModuleManifest]
    }

    private struct Lockfile: Codable {
        let formatVersion: Int
        let modules: [String]
    }

    private let modulesByID: [String: PearfyModuleManifest]
    private let beginMarker = "// pearfy-modules:begin"
    private let endMarker = "// pearfy-modules:end"

    public init(registryData: Data? = nil) throws {
        let data: Data
        if let registryData {
            data = registryData
        } else {
            guard let url = Bundle.module.url(forResource: "module-registry", withExtension: "json") else {
                throw PearfyModuleManagerError.invalidRegistry("resource module-registry.json is missing")
            }
            data = try Data(contentsOf: url)
        }
        let registry: RegistryFile
        do {
            registry = try JSONDecoder().decode(RegistryFile.self, from: data)
        } catch {
            throw PearfyModuleManagerError.invalidRegistry(String(describing: error))
        }
        guard registry.schemaVersion == 1 else {
            throw PearfyModuleManagerError.invalidRegistry("unsupported schemaVersion \(registry.schemaVersion)")
        }
        var modules: [String: PearfyModuleManifest] = [:]
        for module in registry.modules {
            guard Self.isValidModuleID(module.id),
                  modules[module.id] == nil,
                  Set(module.products).count == module.products.count,
                  module.products.allSatisfy(Self.isValidProductName) else {
                throw PearfyModuleManagerError.invalidRegistry("invalid or duplicate module '\(module.id)'")
            }
            modules[module.id] = module
        }
        guard modules["http"] != nil else {
            throw PearfyModuleManagerError.invalidRegistry("required base module 'http' is missing")
        }
        modulesByID = modules
        for id in modules.keys.sorted() { _ = try resolvedModules(for: [id]) }
    }

    public func availableModules() -> [PearfyModuleManifest] {
        modulesByID.values.sorted { $0.id < $1.id }
    }

    public func module(named id: String) throws -> PearfyModuleManifest {
        guard let module = modulesByID[id] else { throw PearfyModuleManagerError.unknownModule(id) }
        return module
    }

    public func planAdding(_ id: String, to selectedModules: [String]) throws -> PearfyModulePlan {
        _ = try module(named: id)
        let current = Set(selectedModules)
        let planned = current.union([id])
        let currentResolved = try resolvedModules(for: current)
        let plannedResolved = try resolvedModules(for: planned)
        let currentProducts = products(for: currentResolved)
        let plannedProducts = products(for: plannedResolved)
        return PearfyModulePlan(
            action: "add",
            module: id,
            currentModules: selectedModules.sorted(),
            plannedModules: planned.sorted(),
            productsToAdd: plannedProducts.subtracting(currentProducts).sorted(),
            productsToRemove: currentProducts.subtracting(plannedProducts).sorted()
        )
    }

    public func planRemoving(_ id: String, from selectedModules: [String]) throws -> PearfyModulePlan {
        _ = try module(named: id)
        guard id != "http" else { throw PearfyModuleManagerError.requiredBaseModule(id) }
        var planned = Set(selectedModules)
        let currentResolved = try resolvedModules(for: planned)
        guard planned.remove(id) != nil else {
            let dependents = currentResolved
                .filter { modulesByID[$0]?.requirements.contains(id) == true }
                .sorted()
            if !dependents.isEmpty { throw PearfyModuleManagerError.requiredModule(id, by: dependents) }
            return PearfyModulePlan(
                action: "remove",
                module: id,
                currentModules: selectedModules.sorted(),
                plannedModules: selectedModules.sorted(),
                productsToAdd: [],
                productsToRemove: []
            )
        }
        let plannedResolved = try resolvedModules(for: planned)
        if plannedResolved.contains(id) {
            let dependents = plannedResolved.filter { modulesByID[$0]?.requirements.contains(id) == true }.sorted()
            throw PearfyModuleManagerError.requiredModule(id, by: dependents)
        }
        let currentProducts = products(for: currentResolved)
        let plannedProducts = products(for: plannedResolved)
        return PearfyModulePlan(
            action: "remove",
            module: id,
            currentModules: selectedModules.sorted(),
            plannedModules: planned.sorted(),
            productsToAdd: plannedProducts.subtracting(currentProducts).sorted(),
            productsToRemove: currentProducts.subtracting(plannedProducts).sorted()
        )
    }

    public func apply(_ plan: PearfyModulePlan, to projectRoot: URL) throws {
        let lockURL = projectRoot.appendingPathComponent(".pearfy/modules.json")
        let packageURL = projectRoot.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: lockURL.path),
              FileManager.default.fileExists(atPath: packageURL.path) else {
            throw PearfyModuleManagerError.managedProjectRequired
        }
        let lockData = try Data(contentsOf: lockURL)
        let lockfile: Lockfile
        do {
            lockfile = try JSONDecoder().decode(Lockfile.self, from: lockData)
        } catch {
            throw PearfyModuleManagerError.invalidLockfile
        }
        guard lockfile.formatVersion == 1 else { throw PearfyModuleManagerError.invalidLockfile }
        guard lockfile.modules.contains("http"), Set(lockfile.modules).count == lockfile.modules.count else {
            throw PearfyModuleManagerError.invalidLockfile
        }
        guard lockfile.modules.sorted() == plan.currentModules else { throw PearfyModuleManagerError.stalePlan }

        let oldManifestData = try Data(contentsOf: packageURL)
        let oldManifest = String(decoding: oldManifestData, as: UTF8.self)
        let currentResolved = try resolvedModules(for: Set(lockfile.modules))
        guard try existingProductBlock(in: oldManifest) == productBlock(modules: currentResolved) else {
            throw PearfyModuleManagerError.packageDrift
        }
        let updatedManifest = try replacingProductBlock(in: oldManifest, modules: plan.plannedModules)
        let updatedLock = try lockfileData(modules: plan.plannedModules)

        try updatedLock.write(to: lockURL, options: .atomic)
        do {
            try Data(updatedManifest.utf8).write(to: packageURL, options: .atomic)
        } catch {
            try? oldManifestData.write(to: packageURL, options: .atomic)
            try? lockData.write(to: lockURL, options: .atomic)
            throw error
        }
    }

    public func doctor(projectRoot: URL) throws -> [String] {
        let lockURL = projectRoot.appendingPathComponent(".pearfy/modules.json")
        let packageURL = projectRoot.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: lockURL.path),
              FileManager.default.fileExists(atPath: packageURL.path) else {
            throw PearfyModuleManagerError.managedProjectRequired
        }
        let lockfile: Lockfile
        do {
            lockfile = try JSONDecoder().decode(Lockfile.self, from: Data(contentsOf: lockURL))
        } catch {
            throw PearfyModuleManagerError.invalidLockfile
        }
        guard lockfile.formatVersion == 1 else { throw PearfyModuleManagerError.invalidLockfile }
        guard lockfile.modules.contains("http"), Set(lockfile.modules).count == lockfile.modules.count else {
            throw PearfyModuleManagerError.invalidLockfile
        }
        let resolved = try resolvedModules(for: Set(lockfile.modules))
        let manifest = String(decoding: try Data(contentsOf: packageURL), as: UTF8.self)
        let expected = try productBlock(modules: resolved)
        let actual = try existingProductBlock(in: manifest)
        guard expected == actual else {
            throw PearfyModuleManagerError.invalidRegistry(
                "Package.swift dependency block differs from .pearfy/modules.json (expected \(expected), found \(actual))"
            )
        }
        return lockfile.modules.sorted()
    }

    public func render(_ plan: PearfyModulePlan) -> String {
        let added = plan.productsToAdd.isEmpty ? "none" : plan.productsToAdd.joined(separator: ", ")
        let removed = plan.productsToRemove.isEmpty ? "none" : plan.productsToRemove.joined(separator: ", ")
        return """
        Module plan: \(plan.action) \(plan.module)
        Selected modules: \(plan.plannedModules.joined(separator: ", "))
        Products to add: \(added)
        Products to remove: \(removed)
        Changes are limited to Package.swift's Pearfy markers and .pearfy/modules.json.
        """
    }

    public func initialLockfileData() throws -> Data {
        try lockfileData(modules: ["http"])
    }

    private func lockfileData(modules: [String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let value = Lockfile(formatVersion: 1, modules: modules.sorted())
        return try encoder.encode(value) + Data([0x0a])
    }

    private func resolvedModules(for roots: Set<String>) throws -> Set<String> {
        var resolved: Set<String> = []
        var active: [String] = []

        func visit(_ id: String) throws {
            guard let module = modulesByID[id] else { throw PearfyModuleManagerError.unknownModule(id) }
            if resolved.contains(id) { return }
            if active.contains(id) {
                let cycle = (active + [id]).joined(separator: " -> ")
                throw PearfyModuleManagerError.invalidRegistry("dependency cycle: \(cycle)")
            }
            active.append(id)
            for dependency in module.requirements.sorted() { try visit(dependency) }
            active.removeLast()
            resolved.insert(id)
        }

        try visit("http")
        for id in roots.sorted() { try visit(id) }
        return resolved
    }

    private func products(for modules: Set<String>) -> Set<String> {
        Set(modules.flatMap { modulesByID[$0]?.products ?? [] })
    }

    private func productBlock(modules: Set<String>) throws -> [String] {
        let productNames = products(for: modules).sorted()
        guard !productNames.isEmpty else { throw PearfyModuleManagerError.invalidRegistry("module graph has no products") }
        return ["// pearfy-modules:begin"]
            + productNames.map { ".product(name: \"\($0)\", package: \"Pearfy\")," }
            + ["// pearfy-modules:end"]
    }

    private func existingProductBlock(in manifest: String) throws -> [String] {
        let lines = manifest.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == beginMarker }),
              let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == endMarker }),
              start < end else {
            throw PearfyModuleManagerError.managedProjectRequired
        }
        return Array(lines[start...end]).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func replacingProductBlock(in manifest: String, modules: [String]) throws -> String {
        let lines = manifest.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == beginMarker }),
              let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == endMarker }),
              start < end else {
            throw PearfyModuleManagerError.managedProjectRequired
        }
        let resolved = try resolvedModules(for: Set(modules))
        let rawReplacement = try productBlock(modules: resolved)
        let replacement = rawReplacement.map { "                \($0)" }
        var output = Array(lines[..<start]) + replacement
        if end + 1 < lines.count { output += lines[(end + 1)...] }
        return output.joined(separator: "\n")
    }

    private static func isValidModuleID(_ id: String) -> Bool {
        guard let first = id.utf8.first, (97...122).contains(first) else { return false }
        return id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    private static func isValidProductName(_ product: String) -> Bool {
        guard let first = product.utf8.first, (65...90).contains(first) || (97...122).contains(first) else { return false }
        return product.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }
    }
}

/// CLI façade for module inventory and safe edits to generated scaffold manifests.
public enum PearfyModuleCommand {
    public static func run(_ arguments: [String], projectRoot: URL) throws -> Int32 {
        let manager = try PearfyModuleManager()
        guard let command = arguments.first else { throw PearfyModuleCommandError.usage }
        switch command {
        case "list":
            for module in manager.availableModules() {
                print("\(module.id)\t\(module.summary)")
            }
        case "info":
            guard arguments.count == 2 else { throw PearfyModuleCommandError.usage }
            let module = try manager.module(named: arguments[1])
            print("\(module.id): \(module.summary)")
            print("Requires: \(module.requirements.isEmpty ? "none" : module.requirements.joined(separator: ", "))")
            print("Products: \(module.products.joined(separator: ", "))")
        case "doctor":
            let modules = try manager.doctor(projectRoot: projectRoot)
            print("Module configuration OK: \(modules.sorted().joined(separator: ", "))")
        case "plan":
            guard arguments.count == 3 else { throw PearfyModuleCommandError.usage }
            let projectModules = try manager.doctor(projectRoot: projectRoot)
            let action = String(arguments[1].dropFirst(2))
            let plan: PearfyModulePlan
            switch action {
            case "add": plan = try manager.planAdding(arguments[2], to: projectModules)
            case "remove": plan = try manager.planRemoving(arguments[2], from: projectModules)
            default: throw PearfyModuleCommandError.usage
            }
            print(manager.render(plan))
        default:
            throw PearfyModuleCommandError.usage
        }
        return 0
    }

    public static func modify(_ action: String, module: String, projectRoot: URL, dryRun: Bool) throws -> Int32 {
        let manager = try PearfyModuleManager()
        let current = try manager.doctor(projectRoot: projectRoot)
        let plan = try action == "add"
            ? manager.planAdding(module, to: current)
            : manager.planRemoving(module, from: current)
        print(manager.render(plan))
        if dryRun { return 0 }
        try manager.apply(plan, to: projectRoot)
        print("Applied module plan. Run swift build to verify the updated package.")
        return 0
    }
}

private enum PearfyModuleCommandError: Error, CustomStringConvertible {
    case usage

    var description: String {
        switch self {
        case .usage:
            "Usage: pearfy modules <list|info <id>|doctor|plan --add|--remove <id>>; pearfy <add|remove> <id> [--dry-run]"
        }
    }
}

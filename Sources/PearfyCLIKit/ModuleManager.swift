import Foundation

public enum PearfyModuleImplementationStatus: String, Codable, Sendable {
    case implemented
    case partial
    case planned
}

public struct PearfySDKRelease: Codable, Equatable, Sendable {
    public let version: String
    public let name: String
    public let summary: String
    public let modules: [String]
    public let commands: [String]
}

public struct PearfyModuleProjectStatusSemantics: Codable, Equatable, Sendable {
    public let installed: String
    public let configured: String
    public let operational: String
}

public struct PearfyModuleManifest: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// `workspace` means the product has no separately released SwiftPM version.
    public let version: String
    public let implementationStatus: PearfyModuleImplementationStatus
    public let available: Bool
    public let summary: String
    public let requirements: [String]
    public let products: [String]
    /// SwiftPM package traits required by the products in this module.
    public let packageTraits: [String]
    public let capabilities: [String]
    public let configurationChecks: [String]
    public let skillID: String?
    public let skillVersion: String?
    public let references: [String]
    public let cliCommands: [String]
    public let contracts: [String]
    public let restrictions: [String]
    public let validation: [String]
    public let mcpTools: [String]
    public let mcpResources: [String]
    public let mcpResourceTemplates: [String]
    public let introducedInSDK: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case version
        case implementationStatus
        case available
        case summary
        case requirements = "requires"
        case products
        case packageTraits
        case capabilities
        case configurationChecks
        case skillID = "skill"
        case skillVersion
        case references
        case cliCommands
        case contracts
        case restrictions
        case validation
        case mcpTools
        case mcpResources
        case mcpResourceTemplates
        case introducedInSDK
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try values.decodeIfPresent(String.self, forKey: .version) ?? "workspace"
        implementationStatus = try values.decodeIfPresent(PearfyModuleImplementationStatus.self, forKey: .implementationStatus) ?? .partial
        available = try values.decodeIfPresent(Bool.self, forKey: .available) ?? true
        summary = try values.decode(String.self, forKey: .summary)
        requirements = try values.decodeIfPresent([String].self, forKey: .requirements) ?? []
        products = try values.decodeIfPresent([String].self, forKey: .products) ?? []
        packageTraits = try values.decodeIfPresent([String].self, forKey: .packageTraits) ?? []
        capabilities = try values.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        configurationChecks = try values.decodeIfPresent([String].self, forKey: .configurationChecks) ?? []
        skillID = try values.decodeIfPresent(String.self, forKey: .skillID)
        skillVersion = try values.decodeIfPresent(String.self, forKey: .skillVersion)
        references = try values.decodeIfPresent([String].self, forKey: .references) ?? []
        cliCommands = try values.decodeIfPresent([String].self, forKey: .cliCommands) ?? []
        contracts = try values.decodeIfPresent([String].self, forKey: .contracts) ?? []
        restrictions = try values.decodeIfPresent([String].self, forKey: .restrictions) ?? []
        validation = try values.decodeIfPresent([String].self, forKey: .validation) ?? []
        mcpTools = try values.decodeIfPresent([String].self, forKey: .mcpTools) ?? []
        mcpResources = try values.decodeIfPresent([String].self, forKey: .mcpResources) ?? []
        mcpResourceTemplates = try values.decodeIfPresent([String].self, forKey: .mcpResourceTemplates) ?? []
        introducedInSDK = try values.decodeIfPresent(String.self, forKey: .introducedInSDK)
    }
}

public struct PearfyModulePlan: Equatable, Sendable {
    public let action: String
    public let module: String
    public let currentModules: [String]
    public let plannedModules: [String]
    public let productsToAdd: [String]
    public let productsToRemove: [String]
    public let packageTraitsToEnable: [String]
    public let packageTraitsToDisable: [String]
}

public enum PearfyModuleManagerError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidRegistry(String)
    case unknownModule(String)
    case moduleUnavailable(String)
    case moduleNotSelected(String)
    case requiredModule(String, by: [String])
    case requiredBaseModule(String)
    case managedProjectRequired
    case invalidLockfile
    case moduleVersionDrift(String, locked: String, current: String)
    case stalePlan
    case packageDrift

    public var description: String {
        switch self {
        case .invalidRegistry(let detail): "PEARFY_MODULE_001: invalid module registry: \(detail)"
        case .unknownModule(let id): "PEARFY_MODULE_002: module '\(id)' is not available in this checkout"
        case .moduleUnavailable(let id): "PEARFY_MODULE_010: module '\(id)' is documented but not implemented/available in this checkout"
        case .moduleNotSelected(let id): "PEARFY_MODULE_003: module '\(id)' is not selected in this project"
        case .requiredModule(let id, let dependents):
            "PEARFY_MODULE_004: module '\(id)' is required by \(dependents.joined(separator: ", "))"
        case .requiredBaseModule(let id): "PEARFY_MODULE_005: base module '\(id)' cannot be removed"
        case .managedProjectRequired: "PEARFY_MODULE_006: project has no Pearfy module-manager markers; no files were changed"
        case .invalidLockfile: "PEARFY_MODULE_007: .pearfy/modules.json is missing or invalid"
        case .moduleVersionDrift(let id, let locked, let current):
            "PEARFY_MODULE_011: module '\(id)' version drift (lock: \(locked), registry: \(current)); review the SDK/module update before changing dependencies"
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
        let sdkReleases: [PearfySDKRelease]?
        let projectStatusSemantics: PearfyModuleProjectStatusSemantics?
        let modules: [PearfyModuleManifest]
    }

    private struct Lockfile: Codable {
        let formatVersion: Int
        let modules: [String]
        let moduleVersions: [String: String]?
    }

    private let modulesByID: [String: PearfyModuleManifest]
    private let releases: [PearfySDKRelease]
    private let statusSemantics: PearfyModuleProjectStatusSemantics
    private let beginMarker = "// pearfy-modules:begin"
    private let endMarker = "// pearfy-modules:end"
    private let traitsBeginMarker = "// pearfy-package-traits:begin"
    private let traitsEndMarker = "// pearfy-package-traits:end"

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
        guard registry.schemaVersion == 1 || registry.schemaVersion == 2 else {
            throw PearfyModuleManagerError.invalidRegistry("unsupported schemaVersion \(registry.schemaVersion)")
        }
        var modules: [String: PearfyModuleManifest] = [:]
        for module in registry.modules {
            guard Self.isValidModuleID(module.id),
                  modules[module.id] == nil,
                  Set(module.products).count == module.products.count,
                  Set(module.mcpTools).count == module.mcpTools.count,
                  Set(module.mcpResources).count == module.mcpResources.count,
                  Set(module.mcpResourceTemplates).count == module.mcpResourceTemplates.count,
                  module.products.allSatisfy(Self.isValidProductName),
                  !module.available || (!module.products.isEmpty && module.implementationStatus != .planned),
                  module.available || (module.implementationStatus == .planned && module.mcpTools.isEmpty && module.mcpResources.isEmpty && module.mcpResourceTemplates.isEmpty),
                  registry.schemaVersion != 2 || !module.available || (module.skillID != nil && module.skillVersion != nil) else {
                throw PearfyModuleManagerError.invalidRegistry("invalid or duplicate module '\(module.id)'")
            }
            modules[module.id] = module
        }
        let mcpToolNames = registry.modules.flatMap(\.mcpTools)
        guard Set(mcpToolNames).count == mcpToolNames.count,
              mcpToolNames.allSatisfy(Self.isValidMCPToolName) else {
            throw PearfyModuleManagerError.invalidRegistry("invalid or duplicate MCP tool name")
        }
        guard modules["http"] != nil else {
            throw PearfyModuleManagerError.invalidRegistry("required base module 'http' is missing")
        }
        modulesByID = modules
        releases = registry.sdkReleases ?? []
        statusSemantics = registry.projectStatusSemantics ?? PearfyModuleProjectStatusSemantics(
            installed: "not recorded by this legacy registry",
            configured: "not verified",
            operational: "not verified"
        )
        if registry.schemaVersion == 2, registry.projectStatusSemantics == nil {
            throw PearfyModuleManagerError.invalidRegistry("schemaVersion 2 requires projectStatusSemantics")
        }
        guard Set(releases.map(\.version)).count == releases.count,
              releases.allSatisfy({ !$0.version.isEmpty && $0.modules.allSatisfy { modules[$0]?.available == true } }) else {
            throw PearfyModuleManagerError.invalidRegistry("invalid SDK release catalog")
        }
        for id in modules.values.filter(\.available).map(\.id).sorted() { _ = try resolvedModules(for: [id]) }
    }

    public func availableModules() -> [PearfyModuleManifest] {
        modulesByID.values.filter(\.available).sorted { $0.id < $1.id }
    }

    public func catalogModules() -> [PearfyModuleManifest] {
        modulesByID.values.sorted { $0.id < $1.id }
    }

    public func sdkReleases() -> [PearfySDKRelease] {
        releases
    }

    public func projectStatusSemantics() -> PearfyModuleProjectStatusSemantics {
        statusSemantics
    }

    public func module(named id: String) throws -> PearfyModuleManifest {
        guard let module = modulesByID[id] else { throw PearfyModuleManagerError.unknownModule(id) }
        return module
    }

    /// Explicit module selections from the lock file, after manifest/version validation.
    public func selectedModuleIDs(projectRoot: URL) throws -> [String] {
        try doctor(projectRoot: projectRoot)
    }

    /// Explicit selections plus their available transitive dependencies.
    public func resolvedModuleIDs(projectRoot: URL) throws -> [String] {
        let selected = try doctor(projectRoot: projectRoot)
        return try resolvedModules(for: Set(selected)).sorted()
    }

    public func resolvedModuleIDs(from selections: [String]) throws -> [String] {
        try resolvedModules(for: Set(selections)).sorted()
    }

    public func projectModuleVersions(projectRoot: URL) throws -> [String: String]? {
        let url = projectRoot.appendingPathComponent(".pearfy/modules.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let lockfile: Lockfile
        do {
            lockfile = try JSONDecoder().decode(Lockfile.self, from: Data(contentsOf: url))
        } catch {
            throw PearfyModuleManagerError.invalidLockfile
        }
        guard lockfile.formatVersion == 1 || lockfile.formatVersion == 2 else {
            throw PearfyModuleManagerError.invalidLockfile
        }
        return lockfile.moduleVersions
    }

    /// Upgrades a legacy version-1 lock without changing its module selection or manifest.
    public func upgradeLockfile(projectRoot: URL) throws {
        let selected = try doctor(projectRoot: projectRoot)
        let data = try lockfileData(modules: selected)
        try data.write(to: projectRoot.appendingPathComponent(".pearfy/modules.json"), options: .atomic)
    }

    public func planAdding(_ id: String, to selectedModules: [String]) throws -> PearfyModulePlan {
        let requested = try module(named: id)
        guard requested.available else { throw PearfyModuleManagerError.moduleUnavailable(id) }
        let current = Set(selectedModules)
        let planned = current.union([id])
        let currentResolved = try resolvedModules(for: current)
        let plannedResolved = try resolvedModules(for: planned)
        let currentProducts = products(for: currentResolved)
        let plannedProducts = products(for: plannedResolved)
        let currentTraits = packageTraits(for: currentResolved)
        let plannedTraits = packageTraits(for: plannedResolved)
        return PearfyModulePlan(
            action: "add",
            module: id,
            currentModules: selectedModules.sorted(),
            plannedModules: planned.sorted(),
            productsToAdd: plannedProducts.subtracting(currentProducts).sorted(),
            productsToRemove: currentProducts.subtracting(plannedProducts).sorted(),
            packageTraitsToEnable: plannedTraits.subtracting(currentTraits).sorted(),
            packageTraitsToDisable: currentTraits.subtracting(plannedTraits).sorted()
        )
    }

    public func planRemoving(_ id: String, from selectedModules: [String]) throws -> PearfyModulePlan {
        let requested = try module(named: id)
        guard requested.available else { throw PearfyModuleManagerError.moduleUnavailable(id) }
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
                productsToRemove: [],
                packageTraitsToEnable: [],
                packageTraitsToDisable: []
            )
        }
        let plannedResolved = try resolvedModules(for: planned)
        if plannedResolved.contains(id) {
            let dependents = plannedResolved.filter { modulesByID[$0]?.requirements.contains(id) == true }.sorted()
            throw PearfyModuleManagerError.requiredModule(id, by: dependents)
        }
        let currentProducts = products(for: currentResolved)
        let plannedProducts = products(for: plannedResolved)
        let currentTraits = packageTraits(for: currentResolved)
        let plannedTraits = packageTraits(for: plannedResolved)
        return PearfyModulePlan(
            action: "remove",
            module: id,
            currentModules: selectedModules.sorted(),
            plannedModules: planned.sorted(),
            productsToAdd: plannedProducts.subtracting(currentProducts).sorted(),
            productsToRemove: currentProducts.subtracting(plannedProducts).sorted(),
            packageTraitsToEnable: plannedTraits.subtracting(currentTraits).sorted(),
            packageTraitsToDisable: currentTraits.subtracting(plannedTraits).sorted()
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
        guard lockfile.formatVersion == 1 || lockfile.formatVersion == 2 else { throw PearfyModuleManagerError.invalidLockfile }
        guard lockfile.modules.contains("http"), Set(lockfile.modules).count == lockfile.modules.count else {
            throw PearfyModuleManagerError.invalidLockfile
        }
        guard lockfile.modules.sorted() == plan.currentModules else { throw PearfyModuleManagerError.stalePlan }

        let oldManifestData = try Data(contentsOf: packageURL)
        let oldManifest = String(decoding: oldManifestData, as: UTF8.self)
        let currentResolved = try resolvedModules(for: Set(lockfile.modules))
        try validateVersionLock(lockfile, resolvedModules: currentResolved)
        guard try existingProductBlock(in: oldManifest) == productBlock(modules: currentResolved) else {
            throw PearfyModuleManagerError.packageDrift
        }
        let withProducts = try replacingProductBlock(in: oldManifest, modules: plan.plannedModules)
        let updatedManifest: String
        if oldManifest.contains(traitsBeginMarker) || oldManifest.contains(traitsEndMarker) {
            guard try existingPackageTraitsBlock(in: oldManifest) == packageTraitsBlock(modules: currentResolved) else {
                throw PearfyModuleManagerError.packageDrift
            }
            updatedManifest = try replacingPackageTraitsBlock(in: withProducts, modules: plan.plannedModules)
        } else {
            updatedManifest = try addingPackageTraitsToLegacyDependency(in: withProducts, modules: plan.plannedModules)
        }
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
        guard lockfile.formatVersion == 1 || lockfile.formatVersion == 2 else { throw PearfyModuleManagerError.invalidLockfile }
        guard lockfile.modules.contains("http"), Set(lockfile.modules).count == lockfile.modules.count else {
            throw PearfyModuleManagerError.invalidLockfile
        }
        let resolved = try resolvedModules(for: Set(lockfile.modules))
        try validateVersionLock(lockfile, resolvedModules: resolved)
        let manifest = String(decoding: try Data(contentsOf: packageURL), as: UTF8.self)
        let expected = try productBlock(modules: resolved)
        let actual = try existingProductBlock(in: manifest)
        let traitsAreCurrent: Bool
        if manifest.contains(traitsBeginMarker) || manifest.contains(traitsEndMarker) {
            traitsAreCurrent = try packageTraitsBlock(modules: resolved) == existingPackageTraitsBlock(in: manifest)
        } else {
            // Older CLI scaffolds relied on Pearfy's default traits. They remain
            // manageable and are upgraded to explicit traits on the next change.
            traitsAreCurrent = Self.legacyPearfyDependencyPattern.firstMatch(
                in: manifest,
                range: NSRange(manifest.startIndex..., in: manifest)
            ) != nil
        }
        guard expected == actual, traitsAreCurrent else {
            throw PearfyModuleManagerError.invalidRegistry(
                "Package.swift Pearfy markers differ from .pearfy/modules.json (products expected \(expected), found \(actual); package traits are missing, stale, or malformed)"
            )
        }
        return lockfile.modules.sorted()
    }

    public func render(_ plan: PearfyModulePlan) -> String {
        let added = plan.productsToAdd.isEmpty ? "none" : plan.productsToAdd.joined(separator: ", ")
        let removed = plan.productsToRemove.isEmpty ? "none" : plan.productsToRemove.joined(separator: ", ")
        let traitsEnabled = plan.packageTraitsToEnable.isEmpty ? "none" : plan.packageTraitsToEnable.joined(separator: ", ")
        let traitsDisabled = plan.packageTraitsToDisable.isEmpty ? "none" : plan.packageTraitsToDisable.joined(separator: ", ")
        return """
        Module plan: \(plan.action) \(plan.module)
        Selected modules: \(plan.plannedModules.joined(separator: ", "))
        Products to add: \(added)
        Products to remove: \(removed)
        SwiftPM traits to enable: \(traitsEnabled)
        SwiftPM traits to disable: \(traitsDisabled)
        Changes are limited to Package.swift's Pearfy markers and .pearfy/modules.json.
        """
    }

    public func initialLockfileData() throws -> Data {
        try lockfileData(modules: ["http"])
    }

    private func lockfileData(modules: [String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let resolved = try resolvedModules(for: Set(modules))
        let versions = Dictionary(uniqueKeysWithValues: resolved.sorted().compactMap { id in
            modulesByID[id].map { (id, $0.version) }
        })
        let value = Lockfile(formatVersion: 2, modules: modules.sorted(), moduleVersions: versions)
        return try encoder.encode(value) + Data([0x0a])
    }

    private func validateVersionLock(_ lockfile: Lockfile, resolvedModules: Set<String>) throws {
        guard lockfile.formatVersion == 2 else { return }
        guard let lockedVersions = lockfile.moduleVersions,
              Set(lockedVersions.keys) == resolvedModules else {
            throw PearfyModuleManagerError.invalidLockfile
        }
        for id in resolvedModules.sorted() {
            guard let current = modulesByID[id]?.version,
                  let locked = lockedVersions[id] else {
                throw PearfyModuleManagerError.invalidLockfile
            }
            guard locked == current else {
                throw PearfyModuleManagerError.moduleVersionDrift(id, locked: locked, current: current)
            }
        }
    }

    private func resolvedModules(for roots: Set<String>) throws -> Set<String> {
        var resolved: Set<String> = []
        var active: [String] = []

        func visit(_ id: String) throws {
            guard let module = modulesByID[id] else { throw PearfyModuleManagerError.unknownModule(id) }
            guard module.available else { throw PearfyModuleManagerError.moduleUnavailable(id) }
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

    private func packageTraits(for modules: Set<String>) -> Set<String> {
        Set(modules.flatMap { modulesByID[$0]?.packageTraits ?? [] })
    }

    private func productBlock(modules: Set<String>) throws -> [String] {
        let productNames = products(for: modules).sorted()
        guard !productNames.isEmpty else { throw PearfyModuleManagerError.invalidRegistry("module graph has no products") }
        return ["// pearfy-modules:begin"]
            + productNames.map { ".product(name: \"\($0)\", package: \"Pearfy\")," }
            + ["// pearfy-modules:end"]
    }

    private func packageTraitsBlock(modules: Set<String>) throws -> [String] {
        let traits = packageTraits(for: modules).sorted()
        return [traitsBeginMarker] + traits.map { "\"\($0)\"," } + [traitsEndMarker]
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

    private func existingPackageTraitsBlock(in manifest: String) throws -> [String] {
        let lines = manifest.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == traitsBeginMarker }),
              let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == traitsEndMarker }),
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

    private func replacingPackageTraitsBlock(in manifest: String, modules: [String]) throws -> String {
        let lines = manifest.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == traitsBeginMarker }),
              let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == traitsEndMarker }),
              start < end else {
            throw PearfyModuleManagerError.managedProjectRequired
        }
        let resolved = try resolvedModules(for: Set(modules))
        let replacement = try packageTraitsBlock(modules: resolved).map { "                \($0)" }
        var output = Array(lines[..<start]) + replacement
        if end + 1 < lines.count { output += lines[(end + 1)...] }
        return output.joined(separator: "\n")
    }

    private func addingPackageTraitsToLegacyDependency(in manifest: String, modules: [String]) throws -> String {
        let range = NSRange(manifest.startIndex..., in: manifest)
        guard let match = Self.legacyPearfyDependencyPattern.firstMatch(in: manifest, range: range),
              let pathRange = Range(match.range(at: 1), in: manifest) else {
            throw PearfyModuleManagerError.packageDrift
        }
        let path = String(manifest[pathRange])
        let resolved = try resolvedModules(for: Set(modules))
        let traits = try packageTraitsBlock(modules: resolved).map { "                \($0)" }
        let replacement = ([
            ".package(",
            "            name: \"Pearfy\",",
            "            path: \(path),",
            "            traits: ["
        ] + traits + [
            "            ]",
            "        )"
        ]).joined(separator: "\n")
        guard let replacementRange = Range(match.range, in: manifest) else {
            throw PearfyModuleManagerError.packageDrift
        }
        var output = manifest
        output.replaceSubrange(replacementRange, with: replacement)
        return output
    }

    private static let legacyPearfyDependencyPattern = try! NSRegularExpression(
        pattern: #"\.package\(name:\s*"Pearfy",\s*path:\s*("(?:\\.|[^"\\])*")\)"#
    )

    private static func isValidModuleID(_ id: String) -> Bool {
        guard let first = id.utf8.first, (97...122).contains(first) else { return false }
        return id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    private static func isValidProductName(_ product: String) -> Bool {
        guard let first = product.utf8.first, (65...90).contains(first) || (97...122).contains(first) else { return false }
        return product.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }
    }

    private static func isValidMCPToolName(_ name: String) -> Bool {
        name.hasPrefix("pearfy.") && name.utf8.count <= 128 && name.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}

/// CLI façade for module inventory and safe edits to generated scaffold manifests.
public enum PearfyModuleCommand {
    public static func run(_ arguments: [String], projectRoot: URL) throws -> Int32 {
        let manager = try PearfyModuleManager()
        guard let command = arguments.first else { throw PearfyModuleCommandError.usage }
        switch command {
        case "list":
            for module in manager.catalogModules() {
                let availability = module.available ? "available" : "planned"
                print("\(module.id)\t\(availability)\t\(module.implementationStatus.rawValue)\t\(module.summary)")
            }
        case "info":
            guard arguments.count == 2 else { throw PearfyModuleCommandError.usage }
            let module = try manager.module(named: arguments[1])
            print("\(module.id) [\(module.implementationStatus.rawValue)\(module.available ? ", installable" : ", planned only")] — \(module.name)")
            print("Version: \(module.version)")
            print("Summary: \(module.summary)")
            print("Availability: \(module.available ? "installable" : "planned only")")
            print("Requires: \(module.requirements.isEmpty ? "none" : module.requirements.joined(separator: ", "))")
            print("Products: \(module.products.joined(separator: ", "))")
            print("Skill: \(module.skillID ?? "not available")\(module.skillVersion.map { " @ \($0)" } ?? "")")
            print("Capabilities: \(module.capabilities.isEmpty ? "none implemented" : module.capabilities.joined(separator: "; "))")
            print("Configuration checks: \(module.configurationChecks.isEmpty ? "none declared" : module.configurationChecks.joined(separator: "; "))")
            print("Validation: \(module.validation.isEmpty ? "not available" : module.validation.joined(separator: "; "))")
            print("Runtime configured/operational: not evaluated by registry inspection")
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

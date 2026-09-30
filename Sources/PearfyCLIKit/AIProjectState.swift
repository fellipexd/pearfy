import Crypto
import Foundation

struct PearfyAISettingsSnapshot: Sendable {
    let exists: Bool
    let initialized: Bool
    let client: String
    let mcpModules: Set<String>
    let valid: Bool
}

struct PearfyAIProjectModules: Sendable {
    let discovery: String
    let selected: [String]
    let installed: [String]
    let lockedVersions: [String: String]?
}

struct PearfyAISyncReport: Sendable {
    let installed: Int
    let updated: Int
    let unchanged: Int
    let removed: Int
    let conflicts: [String]
    let skillCount: Int
    let skillBytes: Int
    let agentCount: Int
}

private struct PearfyAIInstallLock: Codable {
    var formatVersion: Int
    var assets: [String: PearfyAIAssetLock]
}

private struct PearfyAIAssetLock: Codable {
    let kind: String
    let version: String
    let moduleVersion: String?
    let files: [String: String]
}

private struct PearfyAISyncCounters {
    var installed = 0
    var updated = 0
    var unchanged = 0
    var removed = 0
    var conflicts: [String] = []
}

private struct PearfyAISyncAsset {
    let key: String
    let kind: String
    let version: String
    let moduleVersion: String?
    let sourceDirectory: URL
    let destinationDirectory: URL
}

enum PearfyAIProjectState {
    private static let stateRelativePath = ".pearfy/ai.json"
    private static let lockRelativePath = ".pearfy/ai-skills.lock.json"
    private static let settingsSchemaVersion = 1

    static func settings(at projectRoot: URL) -> PearfyAISettingsSnapshot {
        let url = projectRoot.appendingPathComponent(stateRelativePath)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? Int,
              version == settingsSchemaVersion,
              let rawModules = object["mcpModules"] as? [String] else {
            return PearfyAISettingsSnapshot(
                exists: FileManager.default.fileExists(atPath: url.path),
                initialized: false,
                client: "generic",
                mcpModules: [],
                valid: !FileManager.default.fileExists(atPath: url.path)
            )
        }
        return PearfyAISettingsSnapshot(
            exists: true,
            initialized: object["initialized"] as? Bool ?? false,
            client: object["client"] as? String ?? "generic",
            mcpModules: Set(rawModules),
            valid: true
        )
    }

    static func enabledMCPModules(projectRoot: URL) -> Set<String> {
        let settings = settings(at: projectRoot)
        return settings.valid ? settings.mcpModules : []
    }

    static func updateSettings(
        projectRoot: URL,
        client: String? = nil,
        initialized: Bool? = nil,
        mcpModules: Set<String>? = nil
    ) throws {
        let url = projectRoot.appendingPathComponent(stateRelativePath)
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard !isSymbolicLink(url) else { throw PearfyAIStateError.unsafeDestination(url.path) }
            let data = try Data(contentsOf: url)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  existing["schemaVersion"] as? Int == settingsSchemaVersion else {
                throw PearfyAIStateError.invalidSettings(url.path)
            }
            object = existing
        }
        object["schemaVersion"] = settingsSchemaVersion
        if let client { object["client"] = client }
        if let initialized { object["initialized"] = initialized }
        if let mcpModules { object["mcpModules"] = mcpModules.sorted() }
        if object["client"] == nil { object["client"] = "generic" }
        if object["initialized"] == nil { object["initialized"] = false }
        if object["mcpModules"] == nil { object["mcpModules"] = [String]() }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try writeAtomically(data, to: url)
    }

    static func setOpenCodeMCPEnabled(projectRoot: URL, enabled: Bool) throws -> String? {
        let jsonURL = projectRoot.appendingPathComponent("opencode.json")
        let jsoncURL = projectRoot.appendingPathComponent("opencode.jsonc")
        guard !FileManager.default.fileExists(atPath: jsoncURL.path) else {
            return "Project opencode.jsonc was preserved; set mcp.pearfy.enabled to \(enabled) there manually."
        }
        guard !isSymbolicLink(jsonURL) else { throw PearfyAIStateError.unsafeDestination(jsonURL.path) }

        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: jsonURL.path) {
            let data = try Data(contentsOf: jsonURL)
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PearfyAIStateError.invalidOpenCodeConfig(jsonURL.path)
            }
            root = decoded
        } else {
            root["$schema"] = "https://opencode.ai/config.json"
        }

        if root["mcp"] != nil, !(root["mcp"] is [String: Any]) {
            throw PearfyAIStateError.invalidOpenCodeConfig(jsonURL.path)
        }
        var mcp = root["mcp"] as? [String: Any] ?? [:]
        if mcp["pearfy"] != nil, !(mcp["pearfy"] is [String: Any]) {
            throw PearfyAIStateError.invalidOpenCodeConfig(jsonURL.path)
        }
        var pearfy = mcp["pearfy"] as? [String: Any] ?? [:]
        if pearfy["type"] == nil { pearfy["type"] = "local" }
        if pearfy["command"] == nil { pearfy["command"] = ["pearfy", "mcp"] }
        if pearfy["timeout"] == nil { pearfy["timeout"] = 10_000 }
        pearfy["enabled"] = enabled
        mcp["pearfy"] = pearfy
        root["mcp"] = mcp

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try writeAtomically(data, to: jsonURL)
        return nil
    }

    static func openCodeMCPEnabled(projectRoot: URL) -> Bool? {
        let url = projectRoot.appendingPathComponent("opencode.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcp = root["mcp"] as? [String: Any],
              let pearfy = mcp["pearfy"] as? [String: Any] else { return nil }
        return pearfy["enabled"] as? Bool
    }

    static func inspectModules(projectRoot: URL, manager: PearfyModuleManager) throws -> PearfyAIProjectModules {
        let lockURL = projectRoot.appendingPathComponent(".pearfy/modules.json")
        if FileManager.default.fileExists(atPath: lockURL.path) {
            let selected = try manager.selectedModuleIDs(projectRoot: projectRoot)
            let installed = try manager.resolvedModuleIDs(projectRoot: projectRoot)
            return PearfyAIProjectModules(
                discovery: "managed-lock",
                selected: selected,
                installed: installed,
                lockedVersions: try manager.projectModuleVersions(projectRoot: projectRoot)
            )
        }

        let packageURL = projectRoot.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            return PearfyAIProjectModules(discovery: "no-swift-package", selected: [], installed: [], lockedVersions: nil)
        }
        let source = try String(contentsOf: packageURL, encoding: .utf8)
        let packageProducts = Self.pearfyProducts(in: source)
        let inferredRoots = manager.catalogModules().filter { module in
            module.available && !module.products.isEmpty && !Set(module.products).isDisjoint(with: packageProducts)
        }.map(\.id)
        guard !inferredRoots.isEmpty else {
            return PearfyAIProjectModules(discovery: "no-pearfy-products-found", selected: [], installed: [], lockedVersions: nil)
        }
        let resolved = try manager.resolvedModuleIDs(from: inferredRoots)
        return PearfyAIProjectModules(
            discovery: "package-product-inference",
            selected: inferredRoots.sorted(),
            installed: resolved,
            lockedVersions: nil
        )
    }

    static func synchronize(
        projectRoot: URL,
        frameworkRoot: URL,
        manager: PearfyModuleManager,
        client: String,
        force: Bool,
        installAgents: Bool
    ) throws -> PearfyAISyncReport {
        let projectModules = try inspectModules(projectRoot: projectRoot, manager: manager)
        let installedManifests = try projectModules.installed.map { try manager.module(named: $0) }
        let skills = Dictionary(grouping: installedManifests.compactMap { module -> PearfyModuleManifest? in
            module.skillID == nil ? nil : module
        }, by: { $0.skillID! })
        try createDirectoryWithoutSymlink(projectRoot.appendingPathComponent(".agents", isDirectory: true))
        if !skills.isEmpty {
            try createDirectoryWithoutSymlink(projectRoot.appendingPathComponent(".agents/skills", isDirectory: true))
        }
        if installAgents {
            try createDirectoryWithoutSymlink(projectRoot.appendingPathComponent(".agents/agents", isDirectory: true))
        }

        var desired: [String: PearfyAISyncAsset] = [:]
        for (skillID, modules) in skills {
            guard let version = modules.compactMap(\.skillVersion).first,
                  modules.allSatisfy({ $0.skillVersion == version }) else {
                throw PearfyAIStateError.inconsistentSkillVersion(skillID)
            }
            let source = frameworkRoot.appendingPathComponent(".agents/skills/\(skillID)", isDirectory: true)
            try validateCanonicalSkill(source, module: modules[0])
            desired["skills/\(skillID)"] = PearfyAISyncAsset(
                key: "skills/\(skillID)",
                kind: "skill",
                version: version,
                moduleVersion: modules[0].version,
                sourceDirectory: source,
                destinationDirectory: projectRoot.appendingPathComponent(".agents/skills/\(skillID)", isDirectory: true)
            )
        }

        let sourceAgents = frameworkRoot.appendingPathComponent(".agents/agents", isDirectory: true)
        let sourceAgentFiles: [URL]
        if installAgents { sourceAgentFiles = try regularMarkdownFiles(in: sourceAgents) }
        else { sourceAgentFiles = [] }
        if installAgents, !sourceAgentFiles.isEmpty {
            desired["agents"] = PearfyAISyncAsset(
                key: "agents",
                kind: "agent",
                version: "1.0.0",
                moduleVersion: nil,
                sourceDirectory: sourceAgents,
                destinationDirectory: projectRoot.appendingPathComponent(".agents/agents", isDirectory: true)
            )
        }

        let lockURL = projectRoot.appendingPathComponent(lockRelativePath)
        var lock = try loadInstallLock(at: lockURL)
        var nextRecords: [String: PearfyAIAssetLock] = [:]
        var counters = PearfyAISyncCounters()
        for asset in desired.values.sorted(by: { $0.key < $1.key }) {
            let old = lock.assets[asset.key]
            let sourceFiles = try markdownFiles(in: asset.sourceDirectory)
            guard !sourceFiles.isEmpty else { throw PearfyAIStateError.emptySkill(asset.key) }
            var nextHashes: [String: String] = [:]
            for sourceFile in sourceFiles {
                let relative = relativePath(of: sourceFile, under: asset.sourceDirectory)
                let bytes = try Data(contentsOf: sourceFile)
                let digest = sha256(bytes)
                let destination = asset.destinationDirectory.appendingPathComponent(relative)
                let previousDigest = old?.files[relative]
                try synchronizeFile(
                    sourceBytes: bytes,
                    sourceDigest: digest,
                    destination: destination,
                    previousDigest: previousDigest,
                    force: force,
                    counters: &counters
                )
                nextHashes[relative] = previousDigest != nil && counters.conflicts.last == destination.path && !force
                    ? previousDigest!
                    : digest
            }

            for stalePath in Set(old?.files.keys.map { $0 } ?? []).subtracting(Set(nextHashes.keys)).sorted() {
                let destination = asset.destinationDirectory.appendingPathComponent(stalePath)
                try removeManagedFile(destination, expectedDigest: old?.files[stalePath], counters: &counters)
            }
            nextRecords[asset.key] = PearfyAIAssetLock(
                kind: asset.kind,
                version: asset.version,
                moduleVersion: asset.moduleVersion,
                files: nextHashes
            )
        }

        for key in lock.assets.keys.sorted() where desired[key] == nil {
            guard let old = lock.assets[key] else { continue }
            let relativeRoot = key.hasPrefix("skills/") ? ".agents/skills/\(key.dropFirst("skills/".count))" : ".agents/agents"
            let destinationRoot = projectRoot.appendingPathComponent(relativeRoot, isDirectory: true)
            for (relative, digest) in old.files.sorted(by: { $0.key < $1.key }) {
                try removeManagedFile(destinationRoot.appendingPathComponent(relative), expectedDigest: digest, counters: &counters)
            }
            cleanupEmptyDirectories(beneath: destinationRoot)
            if key.hasPrefix("skills/"), !FileManager.default.fileExists(atPath: destinationRoot.path) {
                removeOpenCodeSkillLink(projectRoot: projectRoot, skillID: String(key.dropFirst("skills/".count)))
            }
            if key == "agents" {
                for relative in old.files.keys where !FileManager.default.fileExists(atPath: destinationRoot.appendingPathComponent(relative).path) {
                    removeOpenCodeAgentLink(projectRoot: projectRoot, fileName: relative)
                }
            } else if key.hasPrefix("agents/") {
                let name = String(key.dropFirst("agents/".count))
                if !FileManager.default.fileExists(atPath: destinationRoot.appendingPathComponent(name).path) {
                    removeOpenCodeAgentLink(projectRoot: projectRoot, fileName: name)
                }
            }
        }

        lock = PearfyAIInstallLock(formatVersion: 1, assets: nextRecords)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeAtomically(try encoder.encode(lock) + Data([0x0a]), to: lockURL)

        if client == "opencode" {
            for skillID in skills.keys.sorted() {
                if let conflict = try installOpenCodeSkillLink(projectRoot: projectRoot, skillID: skillID) {
                    counters.conflicts.append(conflict)
                }
            }
            for agent in sourceAgentFiles {
                if let conflict = try installOpenCodeAgentLink(projectRoot: projectRoot, fileName: agent.lastPathComponent) {
                    counters.conflicts.append(conflict)
                }
            }
        }

        let totalBytes = try skills.keys.reduce(0) { total, skillID in
            total + (try markdownFiles(in: frameworkRoot.appendingPathComponent(".agents/skills/\(skillID)")).reduce(0) {
                $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            })
        }
        return PearfyAISyncReport(
            installed: counters.installed,
            updated: counters.updated,
            unchanged: counters.unchanged,
            removed: counters.removed,
            conflicts: counters.conflicts,
            skillCount: skills.count,
            skillBytes: totalBytes,
            agentCount: sourceAgentFiles.count
        )
    }

    static func validateCanonicalSkill(_ directory: URL, module: PearfyModuleManifest) throws {
        guard let skillID = module.skillID, let skillVersion = module.skillVersion else {
            throw PearfyAIStateError.moduleSkillUnavailable(module.id)
        }
        let skillFile = directory.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: skillFile, encoding: .utf8),
              frontmatterValue("name", in: text) == skillID,
              frontmatterValue("pearfy-module", in: text) == module.id,
              frontmatterValue("pearfy-skill-version", in: text) == skillVersion else {
            throw PearfyAIStateError.skillMetadataMismatch(skillID)
        }
    }

    static func validateInstalledSkill(_ file: URL, module: PearfyModuleManifest) throws {
        guard let skillID = module.skillID, let skillVersion = module.skillVersion,
              let text = try? String(contentsOf: file, encoding: .utf8),
              frontmatterValue("name", in: text) == skillID,
              frontmatterValue("pearfy-module", in: text) == module.id,
              frontmatterValue("pearfy-skill-version", in: text) == skillVersion else {
            throw PearfyAIStateError.skillMetadataMismatch(module.skillID ?? module.id)
        }
    }

    static func modifiedInstalledSkillFiles(projectRoot: URL, skillID: String) -> [String] {
        let lockURL = projectRoot.appendingPathComponent(lockRelativePath)
        guard let lock = try? loadInstallLock(at: lockURL) else { return [] }
        return modifiedFiles(projectRoot: projectRoot, key: "skills/\(skillID)", record: lock.assets["skills/\(skillID)"])
    }

    static func modifiedInstalledAgentFiles(projectRoot: URL) -> [String] {
        let lockURL = projectRoot.appendingPathComponent(lockRelativePath)
        guard let lock = try? loadInstallLock(at: lockURL) else { return [] }
        return modifiedFiles(projectRoot: projectRoot, key: "agents", record: lock.assets["agents"])
    }

    private static func modifiedFiles(projectRoot: URL, key: String, record: PearfyAIAssetLock?) -> [String] {
        guard let record else { return [] }
        let relativeRoot = key == "agents" ? ".agents/agents" : ".agents/\(key)"
        let directory = projectRoot.appendingPathComponent(relativeRoot, isDirectory: true)
        return record.files.keys.sorted().filter { relative in
            let url = directory.appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: url) else { return true }
            return sha256(data) != record.files[relative]
        }
    }

    static func installedSkillLock(projectRoot: URL, skillID: String) -> (skillVersion: String, moduleVersion: String?)? {
        let lockURL = projectRoot.appendingPathComponent(lockRelativePath)
        guard let lock = try? loadInstallLock(at: lockURL),
              let record = lock.assets["skills/\(skillID)"] else { return nil }
        return (record.version, record.moduleVersion)
    }

    static func hasOpenCodeSkillLink(projectRoot: URL, skillID: String) -> Bool {
        let link = projectRoot.appendingPathComponent(".opencode/skills/\(skillID)")
        return isSymbolicLink(link)
            && (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == "../../.agents/skills/\(skillID)"
    }

    static func hasOpenCodeAgentLink(projectRoot: URL, fileName: String) -> Bool {
        let link = projectRoot.appendingPathComponent(".opencode/agents/\(fileName)")
        return isSymbolicLink(link)
            && (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == "../../.agents/agents/\(fileName)"
    }

    private static func frontmatterValue(_ key: String, in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let prefix = "\(key):"
            guard trimmed.hasPrefix(prefix) else { continue }
            return trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    private static func synchronizeFile(
        sourceBytes: Data,
        sourceDigest: String,
        destination: URL,
        previousDigest: String?,
        force: Bool,
        counters: inout PearfyAISyncCounters
    ) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            guard !isSymbolicLink(destination),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                counters.conflicts.append(destination.path)
                return
            }
            let currentBytes = try Data(contentsOf: destination)
            let currentDigest = sha256(currentBytes)
            if currentDigest == sourceDigest {
                counters.unchanged += 1
                return
            }
            guard force || previousDigest == currentDigest else {
                counters.conflicts.append(destination.path)
                return
            }
            try writeAtomically(sourceBytes, to: destination)
            counters.updated += 1
        } else {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeAtomically(sourceBytes, to: destination)
            counters.installed += 1
        }
    }

    private static func removeManagedFile(
        _ destination: URL,
        expectedDigest: String?,
        counters: inout PearfyAISyncCounters
    ) throws {
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        guard !isSymbolicLink(destination),
              let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            counters.conflicts.append(destination.path)
            return
        }
        let currentDigest = sha256(try Data(contentsOf: destination))
        guard expectedDigest == currentDigest else {
            counters.conflicts.append(destination.path)
            return
        }
        try FileManager.default.removeItem(at: destination)
        counters.removed += 1
    }

    private static func loadInstallLock(at url: URL) throws -> PearfyAIInstallLock {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PearfyAIInstallLock(formatVersion: 1, assets: [:])
        }
        guard !isSymbolicLink(url) else { throw PearfyAIStateError.unsafeDestination(url.path) }
        do {
            let lock = try JSONDecoder().decode(PearfyAIInstallLock.self, from: Data(contentsOf: url))
            guard lock.formatVersion == 1 else { throw PearfyAIStateError.invalidInstallLock(url.path) }
            return lock
        } catch let error as PearfyAIStateError {
            throw error
        } catch {
            throw PearfyAIStateError.invalidInstallLock(url.path)
        }
    }

    private static func markdownFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        guard !isSymbolicLink(directory) else { throw PearfyAIStateError.unsafeSourcePath(directory.path) }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { throw PearfyAIStateError.unreadableSource(directory.path) }
        var result: [URL] = []
        for case let file as URL in enumerator where file.pathExtension == "md" {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                throw PearfyAIStateError.unsafeSourcePath(file.path)
            }
            result.append(file)
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func regularMarkdownFiles(in directory: URL) throws -> [URL] {
        try markdownFiles(in: directory).filter { $0.deletingLastPathComponent() == directory }
    }

    private static func relativePath(of file: URL, under directory: URL) -> String {
        String(file.path.dropFirst(directory.path.count + 1))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func installOpenCodeSkillLink(projectRoot: URL, skillID: String) throws -> String? {
        try installSymlink(
            at: projectRoot.appendingPathComponent(".opencode/skills/\(skillID)"),
            target: "../../.agents/skills/\(skillID)"
        )
    }

    private static func installOpenCodeAgentLink(projectRoot: URL, fileName: String) throws -> String? {
        try installSymlink(
            at: projectRoot.appendingPathComponent(".opencode/agents/\(fileName)"),
            target: "../../.agents/agents/\(fileName)"
        )
    }

    private static func installSymlink(at url: URL, target: String) throws -> String? {
        let clientRoot = url.deletingLastPathComponent().deletingLastPathComponent()
        try createDirectoryWithoutSymlink(clientRoot)
        try createDirectoryWithoutSymlink(url.deletingLastPathComponent())
        if isSymbolicLink(url) {
            let existing = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            return existing == target ? nil : url.path
        }
        guard !FileManager.default.fileExists(atPath: url.path) else { return url.path }
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        return nil
    }

    private static func removeOpenCodeSkillLink(projectRoot: URL, skillID: String) {
        let link = projectRoot.appendingPathComponent(".opencode/skills/\(skillID)")
        guard isSymbolicLink(link),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == "../../.agents/skills/\(skillID)" else { return }
        try? FileManager.default.removeItem(at: link)
    }

    private static func removeOpenCodeAgentLink(projectRoot: URL, fileName: String) {
        let link = projectRoot.appendingPathComponent(".opencode/agents/\(fileName)")
        guard isSymbolicLink(link),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == "../../.agents/agents/\(fileName)" else { return }
        try? FileManager.default.removeItem(at: link)
    }

    private static func cleanupEmptyDirectories(beneath root: URL) {
        guard FileManager.default.fileExists(atPath: root.path), !isSymbolicLink(root),
              let enumerator = FileManager.default.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              ) else { return }
        let directories = (enumerator.allObjects as? [URL] ?? []).filter {
            !isSymbolicLink($0) && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        }.sorted { $0.path.count > $1.path.count }
        for directory in directories + [root] {
            if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    private static func createDirectoryWithoutSymlink(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            guard !isSymbolicLink(directory),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw PearfyAIStateError.unsafeDestination(directory.path)
            }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func pearfyProducts(in packageManifest: String) -> Set<String> {
        let patterns = [
            #"\.product\s*\(\s*name\s*:\s*"([^"]+)"\s*,\s*package\s*:\s*"Pearfy""#,
            #"\.library\s*\(\s*name\s*:\s*"(Pearfy[^"]*)""#
        ]
        var products: Set<String> = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(packageManifest.startIndex..<packageManifest.endIndex, in: packageManifest)
            for match in regex.matches(in: packageManifest, range: range) where match.numberOfRanges > 1 {
                guard let valueRange = Range(match.range(at: 1), in: packageManifest) else { continue }
                products.insert(String(packageManifest[valueRange]))
            }
        }
        return products
    }

}

enum PearfyAIStateError: Error, CustomStringConvertible {
    case invalidSettings(String)
    case invalidOpenCodeConfig(String)
    case invalidInstallLock(String)
    case inconsistentSkillVersion(String)
    case skillMetadataMismatch(String)
    case emptySkill(String)
    case unsafeSourcePath(String)
    case unsafeDestination(String)
    case unreadableSource(String)
    case unsupportedClient(String)
    case moduleSkillUnavailable(String)
    case openCodeJSONCConflict(String)

    var description: String {
        switch self {
        case .invalidSettings(let path): "PEARFY_AI_001: invalid Pearfy AI settings at \(path)"
        case .invalidOpenCodeConfig(let path): "PEARFY_AI_002: invalid OpenCode JSON config at \(path)"
        case .invalidInstallLock(let path): "PEARFY_AI_003: invalid AI asset lock at \(path)"
        case .inconsistentSkillVersion(let skill): "PEARFY_AI_004: modules resolve different Skill versions for '\(skill)'"
        case .skillMetadataMismatch(let skill): "PEARFY_AI_005: SKILL.md metadata does not match Registry for '\(skill)'"
        case .emptySkill(let skill): "PEARFY_AI_006: no Markdown files found for '\(skill)'"
        case .unsafeSourcePath(let path): "PEARFY_AI_007: refusing a symlink/non-file in canonical AI source: \(path)"
        case .unsafeDestination(let path): "PEARFY_AI_008: refusing to write through a non-directory/symlink destination: \(path)"
        case .unreadableSource(let path): "PEARFY_AI_009: cannot enumerate canonical AI source at \(path)"
        case .unsupportedClient(let client): "PEARFY_AI_010: unsupported AI client '\(client)'"
        case .moduleSkillUnavailable(let module): "PEARFY_AI_011: installed module '\(module)' has no implemented Skill"
        case .openCodeJSONCConflict(let path): "PEARFY_AI_012: preserving custom OpenCode JSONC config at \(path); Pearfy MCP enablement must be reconciled manually"
        }
    }
}

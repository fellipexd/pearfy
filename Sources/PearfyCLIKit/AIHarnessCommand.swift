import Foundation

public enum PearfyAICommand {
    private static let initMarkerStart = "<!-- pearfy-ai-context:start -->"
    private static let initMarkerEnd = "<!-- pearfy-ai-context:end -->"

    public static func run(arguments: [String], projectRoot: URL, frameworkRoot: URL) throws -> Int32 {
        guard let action = arguments.first else { throw PearfyAICommandError.usage }
        let remaining = Array(arguments.dropFirst())
        switch action {
        case "init":
            return try initialize(arguments: remaining, projectRoot: projectRoot, frameworkRoot: frameworkRoot)
        case "sync":
            guard remaining.allSatisfy({ $0 == "--force" }), remaining.filter({ $0 == "--force" }).count <= 1 else {
                throw PearfyAICommandError.usage
            }
            return try sync(projectRoot: projectRoot, frameworkRoot: frameworkRoot, force: remaining.contains("--force"))
        case "inspect":
            return try inspect(arguments: remaining, projectRoot: projectRoot, frameworkRoot: frameworkRoot)
        case "doctor":
            guard remaining.isEmpty else { throw PearfyAICommandError.usage }
            return try doctor(projectRoot: projectRoot, frameworkRoot: frameworkRoot)
        case "mcp":
            return try configureMCP(arguments: remaining, projectRoot: projectRoot, frameworkRoot: frameworkRoot)
        default:
            throw PearfyAICommandError.usage
        }
    }

    /// Used by `pearfy add/remove` after the module lock and SwiftPM marker block are updated.
    public static func syncAfterModuleChange(projectRoot: URL, frameworkRoot: URL) throws -> Int32 {
        return try sync(projectRoot: projectRoot, frameworkRoot: frameworkRoot, force: false)
    }

    static func sync(projectRoot: URL, frameworkRoot: URL, force: Bool) throws -> Int32 {
        let manager = try PearfyModuleManager()
        let modules = try PearfyAIProjectState.inspectModules(projectRoot: projectRoot, manager: manager)
        let activeMCPModules = Set(try modules.installed.filter { id in
            try manager.module(named: id).mcpTools.isEmpty == false
        })
        let previous = PearfyAIProjectState.settings(at: projectRoot)
        guard previous.valid else { throw PearfyAICommandError.invalidSettings }
        let client = previous.exists ? previous.client : "generic"
        guard client == "generic" || client == "opencode" else {
            throw PearfyAIStateError.unsupportedClient(client)
        }
        let enabledMCPModules = previous.mcpModules.intersection(activeMCPModules)
        try PearfyAIProjectState.updateSettings(
            projectRoot: projectRoot,
            client: client,
            initialized: previous.exists ? previous.initialized : false,
            mcpModules: enabledMCPModules
        )

        let lockURL = projectRoot.appendingPathComponent(".pearfy/modules.json")
        if FileManager.default.fileExists(atPath: lockURL.path) {
            try manager.upgradeLockfile(projectRoot: projectRoot)
        }

        let report = try PearfyAIProjectState.synchronize(
            projectRoot: projectRoot,
            frameworkRoot: frameworkRoot,
            manager: manager,
            client: client,
            force: force,
            installAgents: previous.initialized
        )
        print("Pearfy AI skills: \(report.installed) installed, \(report.updated) updated, \(report.unchanged) unchanged, \(report.removed) removed")
        print("Selected module Skills: \(report.skillCount); canonical Skill bytes available in project: \(report.skillBytes); OpenCode agent roles: \(report.agentCount)")
        if !previous.mcpModules.subtracting(enabledMCPModules).isEmpty {
            let stale = previous.mcpModules.subtracting(enabledMCPModules).sorted()
            print("Disabled MCP module grants no longer installed: \(stale.joined(separator: ", "))")
        }

        var configurationIncomplete = false
        if client == "opencode" {
            let warning = try PearfyAIProjectState.setOpenCodeMCPEnabled(
                projectRoot: projectRoot,
                enabled: !enabledMCPModules.isEmpty
            )
            if let warning {
                print("INCOMPLETE OpenCode MCP overlay: \(warning)")
                configurationIncomplete = true
            }
        }
        for conflict in report.conflicts {
            print("PRESERVED modified AI file: \(conflict)")
        }
        if !report.conflicts.isEmpty {
            print("Review these files, then rerun `pearfy ai sync`; use `--force` only when replacing the local version is intended.")
            return 1
        }
        return configurationIncomplete ? 2 : 0
    }

    private static func initialize(arguments: [String], projectRoot: URL, frameworkRoot: URL) throws -> Int32 {
        var client: String?
        var seenClient = false
        var index = 0
        while index < arguments.count {
            guard arguments[index] == "--client", !seenClient, index + 1 < arguments.count else {
                throw PearfyAICommandError.usage
            }
            client = arguments[index + 1]
            seenClient = true
            index += 2
        }
        let existing = PearfyAIProjectState.settings(at: projectRoot)
        guard existing.valid else { throw PearfyAICommandError.invalidSettings }
        let selectedClient = client ?? (existing.exists ? existing.client : "generic")
        guard selectedClient == "generic" || selectedClient == "opencode" else {
            throw PearfyAIStateError.unsupportedClient(selectedClient)
        }
        try PearfyAIProjectState.updateSettings(
            projectRoot: projectRoot,
            client: selectedClient,
            initialized: true,
            mcpModules: existing.mcpModules
        )
        try installManagedInstructions(projectRoot: projectRoot)
        print("Initialized Pearfy Skills-first for \(selectedClient) at \(projectRoot.standardizedFileURL.path)")
        return try sync(projectRoot: projectRoot, frameworkRoot: frameworkRoot, force: false)
    }

    private static func installManagedInstructions(projectRoot: URL) throws {
        let agentURL = projectRoot.appendingPathComponent("AGENTS.md")
        let original: String
        if FileManager.default.fileExists(atPath: agentURL.path) {
            guard !((try? agentURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true) else {
                throw PearfyAIStateError.unsafeDestination(agentURL.path)
            }
            original = try String(contentsOf: agentURL, encoding: .utf8)
        } else {
            original = ""
        }
        let block = """
        \(initMarkerStart)
        ## Pearfy Skills-first

        Pearfy module details are loaded progressively. Start with `pearfy ai inspect`, identify installed modules, and read only their `.agents/skills/<skill>/SKILL.md`; open a referenced file only when that contract is needed. The Module Registry is authoritative. Planned modules have no usable API.

        ## Pearfy application discovery

        When asked to create or substantially shape a Pearfy application, first gather missing requirements before choosing modules or writing code. Ask a short, grouped set of concrete questions; do not ask again for details already supplied. Use the CLI's actual architecture profiles (`standard-api`, `financial-transactional`, `social-community`, `realtime-game-server`, `iot-backend`, `high-traffic-platform`, `custom`) as starting points, and confirm the closest fit with the user. Cover the app's core use cases, persistence, authentication/authorization, external integrations, expected traffic/deployment, and whether background work or observability is needed. Keep answers/decisions in project architecture metadata with `pearfy init --decision <key=value>` when applicable. Do not invent profile capabilities; check `pearfy modules info` or `pearfy ai inspect --module <id>` before selecting optional modules.

        If a project has no explicit architecture style, use Clean Architecture as the default and record `architecture.style: clean`; the selected business profile is independent of that style. Keep domain types and rules independent of Pearfy and infrastructure, put use cases in Application, persistence/network adapters in Infrastructure, and HTTP controllers in Presentation. Keep the composition root explicit. Preserve an architecture style already declared by the project. Use `@Service` for actual application services/use cases, `@Repository` for real persistence adapters implementing repository contracts, `@Entity` only for supported persisted schema models, and `@ContractModel` only for API schema DTOs when Connect is selected. Pearfy has no generic domain-model macro; do not invent one, and do not create empty repository/model layers where the application has no such responsibility.

        When creating or migrating Swift application code, inspect the current public Pearfy macro inventory and prefer a supported macro whenever it expresses the same behavior. For HTTP endpoints, use `@RestController` and the matching route/binding/policy macros when applicable, then call the generated `__pearfy_registerRoutes` method explicitly; Pearfy does not auto-register controllers. Use `HTTPRouter` route registration directly only for demonstrated dynamic or infrastructure routes with no suitable macro, and state that exception with its reason. For migrations, classify each relevant macro as applicable, not applicable, or not supported; preserve unresolved behavior and report concrete limitations. Never invent planned macros or insert demonstration routes/components with no application purpose. The canonical inventory is `docs/MACROS.md` and `.agents/skills/pearfy-core/references/macros.md`.

        For a game-server application, read the installed `pearfy-gameserver` Skill and `docs/GAMESERVER.md`, then inspect `pearfy gameserver modes` and the actual starter JSON from `pearfy gameserver template --mode <light|medium|high>`. Ask which mode is the starting target and clarify client transport/protocol, expected concurrent sessions and message rates, player authentication, matchmaking/session allocation, persistence and single- versus multi-instance deployment. Treat template limits as unbenchmarked examples. Explain that Pearfy supplies ticket and matchmaking contracts only: the application still owns authentication, allocation, session lifecycle and transport integration. Keep realtime traffic on authenticated WSS; a high profile leaves UDP disabled. Add the `gameserver` module through the CLI when the user confirms this application needs its contracts.

        Prefer Pearfy CLI operations over MCP. MCP is opt-in per installed module with `pearfy ai mcp enable <module>` and is only for live/dynamic operations. Never use MCP to retrieve static module documentation. Preserve user-owned Skills and configuration during `pearfy ai sync`.

        Before finishing, run the relevant build/tests and `pearfy guardian verify`. Report unavailable gates as INCOMPLETE, never PASS. Keep PearfyAI application runtime separate from development agents. Never expose credentials, request bodies, SQL bindings or private customer data to Skills, MCP, logs or model context.
        \(initMarkerEnd)
        """
        let updated = try replacingManagedBlock(original, start: initMarkerStart, end: initMarkerEnd, block: block)
        try Data(updated.utf8).write(to: agentURL, options: .atomic)
    }

    private static func replacingManagedBlock(_ source: String, start: String, end: String, block: String) throws -> String {
        let startRange = source.range(of: start)
        let endRange = source.range(of: end)
        guard (startRange == nil) == (endRange == nil) else { throw PearfyAICommandError.partialInstructionMarkers }
        if let startRange, let endRange {
            guard startRange.lowerBound < endRange.lowerBound else { throw PearfyAICommandError.partialInstructionMarkers }
            let afterEnd = source.index(endRange.upperBound, offsetBy: 0)
            return String(source[..<startRange.lowerBound]) + block + String(source[afterEnd...])
        }
        if source.isEmpty { return block + "\n" }
        let separator = source.hasSuffix("\n") ? "\n" : "\n\n"
        return source + separator + block + "\n"
    }

    private static func inspect(arguments: [String], projectRoot: URL, frameworkRoot: URL) throws -> Int32 {
        var moduleID: String?
        var scenarios = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--scenarios":
                guard !scenarios else { throw PearfyAICommandError.usage }
                scenarios = true
                index += 1
            case "--module":
                guard moduleID == nil, index + 1 < arguments.count else { throw PearfyAICommandError.usage }
                moduleID = arguments[index + 1]
                index += 2
            default:
                throw PearfyAICommandError.usage
            }
        }

        let manager = try PearfyModuleManager()
        let statusSemantics = manager.projectStatusSemantics()
        if let moduleID {
            let manifest = try manager.module(named: moduleID)
            let project = try PearfyAIProjectState.inspectModules(projectRoot: projectRoot, manager: manager)
            printModule(manifest, installedIDs: Set(project.installed), installedVersions: project.lockedVersions, frameworkRoot: frameworkRoot, projectRoot: projectRoot)
            return 0
        }
        if scenarios {
            try printScenarios(manager: manager, frameworkRoot: frameworkRoot)
            return 0
        }

        let project = try PearfyAIProjectState.inspectModules(projectRoot: projectRoot, manager: manager)
        let settings = PearfyAIProjectState.settings(at: projectRoot)
        let installedIDs = Set(project.installed)
        let skills = installedIDs.compactMap { id -> String? in
            guard let module = try? manager.module(named: id) else { return nil }
            return module.skillID
        }.uniqued.sorted()
        let catalog = manager.catalogModules()
        let sourceSkillCount = Set(catalog.compactMap(\.skillID).filter {
            FileManager.default.fileExists(atPath: frameworkRoot.appendingPathComponent(".agents/skills/\($0)/SKILL.md").path)
        }).count
        let presentSkills = skills.filter {
            FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(".agents/skills/\($0)/SKILL.md").path)
        }
        let presentSkillBytes = presentSkills.reduce(0) {
            $0 + skillMarkdownBytes(projectRoot.appendingPathComponent(".agents/skills/\($1)", isDirectory: true))
        }
        let enabledMCP = settings.valid ? settings.mcpModules.intersection(installedIDs) : []
        let mcpEnabled = PearfyAIProjectState.openCodeMCPEnabled(projectRoot: projectRoot)
        let toolCount = try enabledMCP.reduce(0) { count, id in
            count + (try manager.module(named: id).mcpTools.count)
        }

        print("Pearfy Skills-first inventory")
        print("Project: \(projectRoot.standardizedFileURL.path)")
        print("Module discovery: \(project.discovery)")
        print("Installed module IDs: \(project.installed.isEmpty ? "none detected" : project.installed.joined(separator: ", "))")
        print("SDK capability profiles: \(manager.sdkReleases().map(\.version).joined(separator: ", "))")
        if let versions = project.lockedVersions {
            print("Installed module versions: \(versions.keys.sorted().map { "\($0)=\(versions[$0] ?? "?")" }.joined(separator: ", "))")
        } else {
            print("Installed module versions: unknown (legacy lock or inferred from Package.swift)")
        }
        print("Registry-backed canonical Skills: \(sourceSkillCount); Skills selected by installed modules: \(skills.count) [\(skills.joined(separator: ", "))]")
        print("Skill files present in project: \(presentSkills.count); Markdown bytes including references: \(presentSkillBytes); bodies opened by an LLM are not observable here")
        print("AI project initialized: \(settings.exists && settings.valid && settings.initialized ? "yes" : "no")")
        print("MCP modules enabled: \(enabledMCP.isEmpty ? "none" : enabledMCP.sorted().joined(separator: ", "))")
        print("OpenCode Pearfy MCP: \(mcpEnabled.map { $0 ? "enabled" : "disabled" } ?? "not verified in project config")")
        print("MCP tools exposed by project grants: \(toolCount); live runtime token counts are not available from this client")
        print("Registry status policy: installed=\(statusSemantics.installed) configured=\(statusSemantics.configured) operational=\(statusSemantics.operational)")
        print("\nRegistry catalog (available Skills are not loaded automatically):")
        for module in catalog {
            let isInstalled = installedIDs.contains(module.id)
            let installState = isInstalled ? "installed" : "not-installed"
            let configuredState = !module.available ? "not-applicable" : (isInstalled ? "not-verified" : "not-installed")
            let operationalState = !module.available ? "not-applicable" : (isInstalled ? "not-verified" : "not-run")
            let skill = module.skillID.map { "skill=\($0)@\(module.skillVersion ?? "?")" } ?? "no-implemented-skill"
            let introduced = module.introducedInSDK.map { "introduced-in-sdk=\($0)" } ?? ""
            print("\(module.id)\t\(module.available ? module.implementationStatus.rawValue : "planned/unavailable")\t\(installState)\tconfigured=\(configuredState)\toperational=\(operationalState)\t\(skill)\t\(introduced)\t\(module.summary)")
        }
        print("\nUse `pearfy ai inspect --scenarios` for byte counts of focused Skill sets; no token savings are estimated.")
        return settings.valid ? 0 : 2
    }

    private static func printModule(
        _ module: PearfyModuleManifest,
        installedIDs: Set<String>,
        installedVersions: [String: String]?,
        frameworkRoot: URL,
        projectRoot: URL
    ) {
        let installed = installedIDs.contains(module.id)
        print("Module: \(module.id) — \(module.name)")
        print("Implementation: \(module.implementationStatus.rawValue); available: \(module.available); installed: \(installed)")
        let installedVersion = installed ? (installedVersions?[module.id] ?? "unknown (legacy/inferred)") : "not-installed"
        print("Registry version: \(module.version); installed version: \(installedVersion); configured: \(installed ? "not-verified" : "not-installed"); operational: not-verified")
        print("SDK introduction: \(module.introducedInSDK ?? "not separately versioned")")
        print("Dependencies: \(module.requirements.isEmpty ? "none" : module.requirements.joined(separator: ", "))")
        print("Capabilities: \(module.capabilities.isEmpty ? "none implemented" : module.capabilities.joined(separator: "; "))")
        if let skill = module.skillID {
            let path = frameworkRoot.appendingPathComponent(".agents/skills/\(skill)/SKILL.md")
            let installedPath = projectRoot.appendingPathComponent(".agents/skills/\(skill)/SKILL.md")
            print("Skill: \(skill)@\(module.skillVersion ?? "unknown"); source=\(FileManager.default.fileExists(atPath: path.path)); installed=\(FileManager.default.fileExists(atPath: installedPath.path))")
        } else {
            print("Skill: unavailable (module is not implemented)")
        }
        print("References: \(module.references.isEmpty ? "none" : module.references.joined(separator: ", "))")
        print("CLI: \(module.cliCommands.isEmpty ? "none" : module.cliCommands.joined(separator: "; "))")
        print("Contracts: \(module.contracts.isEmpty ? "none implemented" : module.contracts.joined(separator: ", "))")
        print("Configuration checks: \(module.configurationChecks.isEmpty ? "none declared" : module.configurationChecks.joined(separator: "; "))")
        print("Restrictions: \(module.restrictions.isEmpty ? "none listed" : module.restrictions.joined(separator: "; "))")
        print("Validation: \(module.validation.isEmpty ? "not available" : module.validation.joined(separator: "; "))")
        print("MCP tools: \(module.mcpTools.isEmpty ? "none" : module.mcpTools.joined(separator: ", "))")
    }

    private static func printScenarios(manager: PearfyModuleManager, frameworkRoot: URL) throws {
        let scenarios: [(String, [String], String)] = [
            ("Create a simple REST route", ["http"], "Default to Clean Architecture when the project has no declared style: place the use case/service in Application, the controller in Presentation, and composition in Infrastructure. Prefer applicable public controller, verb, binding, and policy macros; explicitly call the generated route registrar; use HTTPRouter routes only for a documented dynamic/infrastructure exception."),
            ("Create an entity and migration", ["data", "postgres", "transactions"], "Use @Entity/@ID/@Column only for schema models whose stored fields and types fit the current macro; then build SchemaIR and `pearfy migrations generate`; explicitly model PostgreSQL-only constraints, triggers, and seed rows."),
            ("Implement comments in PearfySocial", ["social", "social-postgres", "data"], "Contracts/worker exist; durable content/feed PostgreSQL store is absent."),
            ("Generate a TypeScript SDK", ["connect"], "SDK generation and contract diff are not implemented."),
            ("Create a Populate plan", ["populate"], "Executor is bounded/single-target; run requires explicit approval."),
            ("Investigate a slow route", ["http", "observability", "metric"], "PearfyMetric, structured logs and distributed traces are unavailable; HTTP counters are process-lifetime."),
            ("Simulate an HTTP provider", ["gateway-lab"], "In-process deterministic fake HTTP is available; standalone providers, webhooks, and payments are not implemented.")
        ]
        print("Scenario context inventory (canonical Skill Markdown bytes, not model tokens):")
        for (name, modules, limitation) in scenarios {
            let manifests = try modules.map { try manager.module(named: $0) }
            let skills = manifests.compactMap(\.skillID)
            let unavailable = manifests.filter { !$0.available }.map(\.id)
            let bytes = skills.reduce(0) { partial, skill in
                partial + skillMarkdownBytes(frameworkRoot.appendingPathComponent(".agents/skills/\(skill)", isDirectory: true))
            }
            let toolCount = manifests.reduce(0) { $0 + $1.mcpTools.count }
            print("- \(name): modules=\(modules.joined(separator: ", ")); Skills=\(skills.count) [\(skills.joined(separator: ", "))]; Skill+reference bytes=\(bytes); MCP tool definitions if explicitly enabled=\(toolCount); unavailable=\(unavailable.isEmpty ? "none" : unavailable.joined(separator: ", ")); boundary=\(limitation)")
        }
        print("No LLM was invoked. Actual prompt tokens, corrective edits and task completion quality require client-run experiments and are not estimated here.")
    }

    private static func skillMarkdownBytes(_ directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return 0 }
        var bytes = 0
        for case let file as URL in enumerator where file.pathExtension == "md" {
            bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return bytes
    }

    private static func doctor(projectRoot: URL, frameworkRoot: URL) throws -> Int32 {
        let manager = try PearfyModuleManager()
        let modules = try PearfyAIProjectState.inspectModules(projectRoot: projectRoot, manager: manager)
        let settings = PearfyAIProjectState.settings(at: projectRoot)
        var gates: [(String, Bool, String)] = []
        gates.append(("module-registry", true, "\(manager.catalogModules().count) catalog entries; planned modules are non-installable"))
        gates.append(("project-modules", modules.discovery != "no-swift-package", "\(modules.discovery); \(modules.installed.count) installed/inferred modules"))
        gates.append(("ai-settings", settings.exists && settings.valid && settings.initialized, settings.exists && settings.valid && settings.initialized ? "valid" : "not initialized or invalid; run `pearfy ai init`"))
        let missingReferences = manager.catalogModules().flatMap { module in
            module.references.filter { !FileManager.default.fileExists(atPath: frameworkRoot.appendingPathComponent($0).path) }
                .map { "\(module.id): \($0)" }
        }
        gates.append(("registry-references", missingReferences.isEmpty, missingReferences.isEmpty ? "all cataloged reference paths exist" : "missing catalog references: \(missingReferences.joined(separator: ", "))"))
        let instructionText = try? String(contentsOf: projectRoot.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        let instructionsInstalled = instructionText?.contains(initMarkerStart) == true && instructionText?.contains(initMarkerEnd) == true
        gates.append(("project-instructions", instructionsInstalled, instructionsInstalled ? "managed Pearfy context block is present" : "run `pearfy ai init` to add the small managed block without replacing user text"))

        var sourceSkillsOK = true
        var installedSkillsOK = settings.exists && settings.valid
        var modifiedSkills: [String] = []
        for moduleID in modules.installed {
            guard let module = try? manager.module(named: moduleID), let skillID = module.skillID else { continue }
            let source = frameworkRoot.appendingPathComponent(".agents/skills/\(skillID)", isDirectory: true)
            let target = projectRoot.appendingPathComponent(".agents/skills/\(skillID)", isDirectory: true)
            do {
                try PearfyAIProjectState.validateCanonicalSkill(source, module: module)
            } catch {
                sourceSkillsOK = false
            }
            if module.references.contains(where: { !FileManager.default.fileExists(atPath: frameworkRoot.appendingPathComponent($0).path) }) {
                sourceSkillsOK = false
            }
            let targetSkill = target.appendingPathComponent("SKILL.md")
            if !FileManager.default.fileExists(atPath: targetSkill.path) {
                installedSkillsOK = false
            } else {
                do {
                    try PearfyAIProjectState.validateInstalledSkill(targetSkill, module: module)
                } catch {
                    installedSkillsOK = false
                }
                let installedLock = PearfyAIProjectState.installedSkillLock(projectRoot: projectRoot, skillID: skillID)
                let installedModuleVersion = modules.lockedVersions?[moduleID] ?? module.version
                if installedLock?.skillVersion != module.skillVersion || installedLock?.moduleVersion != installedModuleVersion {
                    installedSkillsOK = false
                }
                modifiedSkills += PearfyAIProjectState.modifiedInstalledSkillFiles(projectRoot: projectRoot, skillID: skillID)
            }
        }
        gates.append(("canonical-skills", sourceSkillsOK, sourceSkillsOK ? "Registry skill names/versions match canonical SKILL.md files" : "missing or mismatched canonical Skill"))
        gates.append(("installed-skills", installedSkillsOK, installedSkillsOK ? "a version-matched Skill exists for each installed module" : "run `pearfy ai sync`; local edits are preserved and reported as conflicts"))
        let uniqueModified = Array(Set(modifiedSkills)).sorted()
        gates.append(("skill-drift", uniqueModified.isEmpty, uniqueModified.isEmpty ? "installed content matches the last synchronized versions" : "modified files preserved: \(uniqueModified.joined(separator: ", "))"))
        let modifiedAgents = PearfyAIProjectState.modifiedInstalledAgentFiles(projectRoot: projectRoot)
        gates.append(("agent-drift", !settings.initialized || modifiedAgents.isEmpty,
            modifiedAgents.isEmpty ? "agent roles match the synchronized baseline" : "modified role files preserved: \(modifiedAgents.joined(separator: ", "))"))

        let invalidMCP = settings.mcpModules.filter { id in
            !modules.installed.contains(id) || (try? manager.module(named: id).mcpTools.isEmpty) != false
        }
        gates.append(("mcp-scope", settings.valid && invalidMCP.isEmpty,
            invalidMCP.isEmpty ? "only installed modules with implemented tools have MCP grants" : "invalid MCP grants: \(invalidMCP.sorted().joined(separator: ", "))"))

        if settings.valid && settings.client == "opencode" {
            let expectedEnabled = settings.initialized && !settings.mcpModules.isEmpty
            let actual = PearfyAIProjectState.openCodeMCPEnabled(projectRoot: projectRoot)
            gates.append(("opencode-mcp", actual == expectedEnabled,
                actual == expectedEnabled ? (expectedEnabled ? "enabled only for explicitly granted modules" : "disabled; Skills and CLI remain active") : "project OpenCode Pearfy MCP enablement was not verified/matched"))
            let links = modules.installed.compactMap { try? manager.module(named: $0).skillID }
            let missingLinks = links.filter { !PearfyAIProjectState.hasOpenCodeSkillLink(projectRoot: projectRoot, skillID: $0) }
            gates.append(("opencode-skill-adapter", missingLinks.isEmpty, missingLinks.isEmpty ? "OpenCode points to canonical project Skills" : "missing Skill adapter links: \(missingLinks.joined(separator: ", "))"))
            let sourceAgents = frameworkRoot.appendingPathComponent(".agents/agents", isDirectory: true)
            let expectedAgents = ((try? FileManager.default.contentsOfDirectory(at: sourceAgents, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "md" }
                .map(\.lastPathComponent)
            let missingAgents = expectedAgents.filter { !PearfyAIProjectState.hasOpenCodeAgentLink(projectRoot: projectRoot, fileName: $0) }
            gates.append(("opencode-agent-adapter", missingAgents.isEmpty, missingAgents.isEmpty ? "specialist roles point to canonical project files" : "missing role adapters: \(missingAgents.joined(separator: ", "))"))
        }

        let hasFail = gates.contains { !$0.1 && $0.0 == "module-registry" }
        let hasIncomplete = gates.contains { !$0.1 }
        for (name, pass, detail) in gates {
            print("\(pass ? "PASS" : (name == "module-registry" ? "FAIL" : "INCOMPLETE")) \(name): \(detail)")
        }
        print("Guardian remains independent: run `pearfy guardian verify`; ai doctor does not mark build/tests PASS.")
        if hasFail { return 1 }
        return hasIncomplete ? 2 : 0
    }

    private static func configureMCP(arguments: [String], projectRoot: URL, frameworkRoot: URL) throws -> Int32 {
        guard let action = arguments.first else { throw PearfyAICommandError.usage }
        if action == "list" {
            guard arguments.count == 1 else { throw PearfyAICommandError.usage }
            let manager = try PearfyModuleManager()
            let inventory = try PearfyAIProjectState.inspectModules(projectRoot: projectRoot, manager: manager)
            let settings = PearfyAIProjectState.settings(at: projectRoot)
            let enabled = settings.valid ? settings.mcpModules : []
            for id in inventory.installed.sorted() {
                let module = try manager.module(named: id)
                guard !module.mcpTools.isEmpty else { continue }
                print("\(enabled.contains(id) ? "enabled" : "disabled") \(id): \(module.mcpTools.count) dynamic tools")
            }
            let available = inventory.installed.reduce(0) { sum, id in
                sum + ((try? manager.module(named: id).mcpTools.count) ?? 0)
            }
            let exposed = inventory.installed.filter(enabled.contains).reduce(0) { sum, id in
                sum + ((try? manager.module(named: id).mcpTools.count) ?? 0)
            }
            print("Available module tools: \(available); enabled for this project: \(exposed)")
            return 0
        }
        guard (action == "enable" || action == "disable"), arguments.count == 2 else {
            throw PearfyAICommandError.usage
        }
        let moduleID = arguments[1]
        let manager = try PearfyModuleManager()
        let module = try manager.module(named: moduleID)
        guard !module.mcpTools.isEmpty else { throw PearfyAICommandError.moduleHasNoMCPTools(moduleID) }
        let inventory = try PearfyAIProjectState.inspectModules(projectRoot: projectRoot, manager: manager)
        guard inventory.installed.contains(moduleID) else { throw PearfyAICommandError.moduleNotInstalled(moduleID) }
        let settings = PearfyAIProjectState.settings(at: projectRoot)
        guard settings.valid else { throw PearfyAICommandError.invalidSettings }
        var enabled = settings.mcpModules
        if action == "enable" { enabled.insert(moduleID) }
        else { enabled.remove(moduleID) }
        try PearfyAIProjectState.updateSettings(projectRoot: projectRoot, initialized: settings.initialized, mcpModules: enabled)
        if settings.client == "opencode" {
            if let warning = try PearfyAIProjectState.setOpenCodeMCPEnabled(projectRoot: projectRoot, enabled: !enabled.isEmpty) {
                print("INCOMPLETE: \(warning)")
                return 2
            }
        }
        print("Pearfy MCP \(action)d for \(moduleID): \(module.mcpTools.count) module-specific tools \(action == "enable" ? "available" : "hidden")")
        if settings.client != "opencode" {
            print("Client is \(settings.client); configure that client's MCP adapter only when this live-data workflow is needed.")
        }
        return 0
    }

}

private enum PearfyAICommandError: Error, CustomStringConvertible {
    case usage
    case invalidSettings
    case partialInstructionMarkers
    case moduleNotInstalled(String)
    case moduleHasNoMCPTools(String)

    var description: String {
        switch self {
        case .usage:
            "Usage: pearfy ai <init [--client opencode]|sync [--force]|inspect [--module <id>|--scenarios]|doctor|mcp <list|enable|disable <module>>>"
        case .invalidSettings: "PEARFY_AI_013: .pearfy/ai.json is invalid; preserve it and repair its Pearfy metadata"
        case .moduleNotInstalled(let id): "PEARFY_AI_014: module '\(id)' must be installed before enabling its MCP tools"
        case .moduleHasNoMCPTools(let id): "PEARFY_AI_015: module '\(id)' has no implemented dynamic MCP tools"
        case .partialInstructionMarkers: "PEARFY_AI_016: AGENTS.md has an incomplete Pearfy managed-block marker; file was left unchanged"
        }
    }
}

private extension Sequence where Element: Hashable {
    var uniqued: [Element] { Array(Set(self)) }
}

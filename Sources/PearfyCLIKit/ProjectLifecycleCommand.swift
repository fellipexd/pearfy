import Foundation

public enum PearfyProjectLifecycleCommand {
    private static let manifestName = "pearfy.project.yml"
    private static let contractRelativePath = ".pearfy/migration/legacy-contract.yml"
    public static let frameworkVersion = "0.1.0"
    public static let cliVersion = "0.1.0"

    private struct Profile {
        let id: String
        let moduleIDs: [String]
        let decisions: [String: PearfyMigrationJSONValue]
    }

    public static func run(
        command: String,
        arguments: [String],
        projectRoot: URL,
        frameworkRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> Int32 {
        switch command {
        case "init":
            return try initialize(arguments: arguments, projectRoot: projectRoot, frameworkRoot: frameworkRoot)
        case "adopt":
            return try adopt(arguments: arguments, projectRoot: projectRoot)
        case "baseline":
            return try baseline(arguments: arguments, projectRoot: projectRoot)
        case "inspect":
            return try inspect(arguments: arguments, projectRoot: projectRoot)
        case "sync":
            return try sync(arguments: arguments, projectRoot: projectRoot)
        case "doctor":
            return try doctor(arguments: arguments, projectRoot: projectRoot)
        case "architecture":
            return try architecture(arguments: arguments, projectRoot: projectRoot)
        case "migrate":
            return try await migrate(arguments: arguments, projectRoot: projectRoot, environment: environment)
        default:
            throw PearfyProjectLifecycleError.usage
        }
    }

    private static func initialize(arguments: [String], projectRoot: URL, frameworkRoot: URL) throws -> Int32 {
        guard let name = arguments.first, !name.hasPrefix("--") else { throw PearfyProjectLifecycleError.usage }
        var path: String?
        var profileName = "standard-api"
        var decisions: [String: PearfyMigrationJSONValue] = [:]
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else { throw PearfyProjectLifecycleError.missingValue(option) }
            let value = arguments[index + 1]
            switch option {
            case "--path":
                guard path == nil else { throw PearfyProjectLifecycleError.duplicateOption(option) }
                path = value
            case "--profile":
                profileName = value
            case "--decision":
                guard let separator = value.firstIndex(of: "=") else { throw PearfyProjectLifecycleError.invalidDecision }
                let key = String(value[..<separator])
                let decision = String(value[value.index(after: separator)...])
                guard isSafeDecisionKey(key), !decision.isEmpty, decision.utf8.count <= 512 else {
                    throw PearfyProjectLifecycleError.invalidDecision
                }
                decisions[key] = .string(decision)
            default:
                throw PearfyProjectLifecycleError.unknownOption(option)
            }
            index += 2
        }
        let profile = try resolveProfile(profileName, decisions: decisions)
        let destination = resolvePath(path, relativeTo: projectRoot)
            ?? projectRoot.appendingPathComponent(name, isDirectory: true)
        let created = try ProjectScaffolder(frameworkRoot: frameworkRoot).createProject(named: name, at: destination)
        do {
            try installProfile(profile, into: created)
            let contract = PearfyLegacyContractDocument(origin: PearfyMigrationOrigin(type: "pearfy", confidence: .high))
            let manifest = try makeManifest(
                root: created,
                mode: .initialize,
                provenance: "cli",
                origin: contract.origin,
                evidence: [],
                contract: contract,
                architecture: PearfyProjectManifest.Architecture(profile: profile.id, decisions: profile.decisions)
            )
            try writeManifest(manifest, contract: contract, root: created)
            try writeHistory("initialized", root: created, references: ["profile:\(profile.id)"])
        } catch {
            try? FileManager.default.removeItem(at: created)
            throw error
        }
        print("Created Pearfy 0.1.0 project \(name) with profile \(profile.id) at \(created.path).")
        print("Run `cd \(created.path) && swift build`; traceability is in \(manifestName).")
        return 0
    }

    private static func adopt(arguments: [String], projectRoot: URL) throws -> Int32 {
        var targetPath: String?
        var name: String?
        var profileName = "standard-api"
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else { throw PearfyProjectLifecycleError.missingValue(option) }
            let value = arguments[index + 1]
            switch option {
            case "--path": targetPath = value
            case "--name": name = value
            case "--profile": profileName = value
            default: throw PearfyProjectLifecycleError.unknownOption(option)
            }
            index += 2
        }
        let root = resolvePath(targetPath, relativeTo: projectRoot) ?? projectRoot.standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) else {
            throw PearfyProjectLifecycleError.compatibleProjectRequired(root.path)
        }
        let analysis = try analyze(root: root, declaredFramework: nil)
        guard isPearfyProject(root: root) else { throw PearfyProjectLifecycleError.pearfyProjectRequired }
        let profile = try resolveProfile(profileName, decisions: [:])
        let old = try loadManifestIfPresent(root: root)
        let contract = try mergeWithExisting(analysis, root: root)
        let manifest = try makeManifest(
            root: root,
            mode: old?.project.mode ?? .adopt,
            provenance: old?.provenance ?? "imported",
            origin: old?.origin ?? contract.origin,
            evidence: contract.evidence,
            contract: contract,
            architecture: old?.architecture ?? PearfyProjectManifest.Architecture(profile: profile.id),
            explicitName: name,
            old: old
        )
        try writeManifest(manifest, contract: contract, root: root)
        try writeHistory(old == nil ? "adopted" : "adopt-reconciled", root: root, references: ["routes:\(contract.routes.count)"])
        print("Pearfy adopted at \(root.path); \(contract.routes.count) legacy routes are in the canonical contract.")
        return 0
    }

    private static func baseline(arguments: [String], projectRoot: URL) throws -> Int32 {
        var targetPath: String?
        var framework: String?
        var profileName: String?
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else { throw PearfyProjectLifecycleError.missingValue(option) }
            let value = arguments[index + 1]
            switch option {
            case "--path": targetPath = value
            case "--framework": framework = try normalizedFramework(value)
            case "--profile": profileName = value
            default: throw PearfyProjectLifecycleError.unknownOption(option)
            }
            index += 2
        }
        let root = resolvePath(targetPath, relativeTo: projectRoot) ?? projectRoot.standardizedFileURL
        guard isPearfyProject(root: root) else { throw PearfyProjectLifecycleError.pearfyProjectRequired }
        let analysis = try analyze(root: root, declaredFramework: framework)
        let old = try loadManifestIfPresent(root: root)
        let contract = try mergeWithExisting(analysis, root: root)
        let profile = try resolveProfile(profileName ?? old?.architecture.profile ?? "standard-api", decisions: old?.architecture.decisions ?? [:])
        let manifest = try makeManifest(
            root: root,
            mode: .baseline,
            provenance: old == nil ? "reconstructed" : old!.provenance,
            origin: moreConfident(old?.origin, contract.origin),
            evidence: contract.evidence,
            contract: contract,
            architecture: old?.architecture ?? PearfyProjectManifest.Architecture(profile: profile.id),
            old: old
        )
        try writeManifest(manifest, contract: contract, root: root)
        try writeHistory("baseline-created", root: root, references: ["routes:\(contract.routes.count)"])
        print("Baseline recorded at \(root.path).")
        print("Detected origin: \(manifest.origin.framework ?? manifest.origin.language ?? "unknown") (\(manifest.origin.confidence.rawValue) confidence)")
        print("Legacy Contract: \(manifest.migration.contractPath); routes discovered: \(contract.routes.count).")
        print("Existing route states were preserved; no application source was generated or rewritten.")
        return 0
    }

    private static func inspect(arguments: [String], projectRoot: URL) throws -> Int32 {
        var targetPath: String?
        var framework: String?
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else { throw PearfyProjectLifecycleError.missingValue(option) }
            let value = arguments[index + 1]
            switch option {
            case "--path": targetPath = value
            case "--framework": framework = try normalizedFramework(value)
            default: throw PearfyProjectLifecycleError.unknownOption(option)
            }
            index += 2
        }
        let root = resolvePath(targetPath, relativeTo: projectRoot) ?? projectRoot.standardizedFileURL
        let analysis = try analyze(root: root, declaredFramework: framework)
        let manifest = try loadManifestIfPresent(root: root)
        let pearfyPresent = isPearfyProject(root: root)
        print("Project inspection (read-only)")
        print("Path: \(root.path)")
        print("Pearfy detected: \(pearfyPresent ? "yes" : "no")")
        print("Traceability manifest: \(manifest == nil ? "missing" : "present")")
        let displayedOrigin = manifest?.origin ?? analysis.origin
        print("Likely origin: \(displayedOrigin.framework ?? displayedOrigin.type) (\(displayedOrigin.confidence.rawValue) confidence)")
        print("Source files analyzed: \(analysis.analyzedFiles)")
        print("Legacy routes discovered: \(analysis.routes.count)")
        if let manifest {
            print("Entry mode: \(manifest.project.mode.rawValue); modules: \(manifest.modules.keys.sorted().joined(separator: ", "))")
        }
        let recommendation = manifest == nil
            ? (pearfyPresent ? "pearfy baseline" : "pearfy migrate")
            : ((manifest?.project.mode == .baseline || manifest?.project.mode == .migrate) ? "pearfy migrate status" : "pearfy doctor")
        print("Recommended action: \(recommendation)")
        print("No files were changed.")
        return 0
    }

    private static func sync(arguments: [String], projectRoot: URL) throws -> Int32 {
        var apply = false
        var targetPath: String?
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--apply":
                guard !apply else { throw PearfyProjectLifecycleError.duplicateOption(option) }
                apply = true
                index += 1
            case "--path":
                guard index + 1 < arguments.count else { throw PearfyProjectLifecycleError.missingValue(option) }
                targetPath = arguments[index + 1]
                index += 2
            default: throw PearfyProjectLifecycleError.unknownOption(option)
            }
        }
        let root = resolvePath(targetPath, relativeTo: projectRoot) ?? projectRoot.standardizedFileURL
        guard let old = try loadManifestIfPresent(root: root) else { throw PearfyProjectLifecycleError.manifestRequired }
        let analysis = try analyze(root: root, declaredFramework: old.origin.framework)
        let oldContract = try loadContractIfPresent(root: root)
        let contract = try mergeWithExisting(analysis, root: root)
        let detectedModules = installedModules(root: root)
        let moduleDrift = Set(old.modules.filter { $0.value }.map(\.key)) != Set(enabledProducts(for: detectedModules).keys)
        let routeDrift = Set(analysis.routes.map(\.key)) != Set(oldContract?.routes.map(\.key) ?? [])
        print("Traceability reconciliation")
        print("Detected routes: \(contract.routes.count); route drift: \(routeDrift ? "yes" : "no")")
        print("Detected modules: \(detectedModules.sorted().joined(separator: ", "))")
        print("Module drift: \(moduleDrift ? "yes" : "no")")
        guard apply else {
            print("Preview only. Re-run `pearfy sync --apply` to update the manifest and Legacy Contract.")
            return 0
        }
        let manifest = try makeManifest(
            root: root,
            mode: old.project.mode,
            provenance: old.provenance,
            origin: moreConfident(old.origin, contract.origin),
            evidence: contract.evidence,
            contract: contract,
            architecture: old.architecture,
            old: old
        )
        try writeManifest(manifest, contract: contract, root: root)
        try writeHistory("traceability-synced", root: root, references: ["route-drift:\(routeDrift)", "module-drift:\(moduleDrift)"])
        print("Traceability manifest and contract reconciled.")
        return 0
    }

    private static func doctor(arguments: [String], projectRoot: URL) throws -> Int32 {
        var targetPath: String?
        if !arguments.isEmpty {
            guard arguments.count == 2, arguments[0] == "--path" else { throw PearfyProjectLifecycleError.usage }
            targetPath = arguments[1]
        }
        let root = resolvePath(targetPath, relativeTo: projectRoot) ?? projectRoot.standardizedFileURL
        guard let manifest = try loadManifestIfPresent(root: root) else {
            print("INCOMPLETE project-tracking: run `pearfy baseline` or `pearfy adopt`")
            return 2
        }
        let contract = try loadContractIfPresent(root: root)
        let routes = contract?.routes ?? []
        let modulesNow = installedModules(root: root)
        let manifestModules = Set(manifest.modules.filter { $0.value }.map(\.key))
        let detectedProducts = Set(enabledProducts(for: modulesNow).keys)
        let drift = detectedProducts != manifestModules
        let elements = contract?.elements ?? []
        let progress = PearfyMigrationProgress(routes: routes, elements: elements)
        print("PASS project-tracking: \(manifest.project.mode.rawValue), Pearfy \(manifest.pearfy.frameworkVersion), CLI \(manifest.pearfy.cliVersion)")
        print("\(contract == nil ? "INCOMPLETE" : "PASS") legacy-contract: \(contract == nil ? "run `pearfy baseline` or `pearfy migrate`" : "\(routes.count) routes recorded")")
        print("\(drift ? "FAIL" : "PASS") module-drift: manifest products \(manifestModules.sorted()) / detected products \(detectedProducts.sorted())")
        let elementConflicts = progress.elements.values.reduce(0) { $0 + $1.conflicts }
        print("\(progress.total > 0 && progress.contractClosed == progress.total ? "PASS" : "INCOMPLETE") e2e-contracts: \(progress.contractClosed)/\(progress.total) routes closed; \(progress.conflicts) route conflicts")
        print("Contract elements: \(elements.count); \(elementConflicts) conflicts")
        if drift || progress.conflicts > 0 || elementConflicts > 0 { return 1 }
        if contract == nil || progress.total == 0 || progress.contractClosed < progress.total { return 2 }
        return 0
    }

    private static func architecture(arguments: [String], projectRoot: URL) throws -> Int32 {
        guard arguments.first == "check", arguments.count == 1 else { throw PearfyProjectLifecycleError.usage }
        guard let manifest = try loadManifestIfPresent(root: projectRoot) else {
            print("INCOMPLETE architecture: project traceability manifest is missing")
            return 2
        }
        let selectedIDs = try selectedModuleIDs(root: projectRoot)
        let profile = try resolveProfile(manifest.architecture.profile, decisions: manifest.architecture.decisions)
        let missing = Set(profile.moduleIDs).subtracting(selectedIDs)
        if missing.isEmpty {
            print("PASS architecture: profile \(profile.id) has required modules \(profile.moduleIDs.joined(separator: ", "))")
            return 0
        }
        print("FAIL architecture: profile \(profile.id) is missing modules \(missing.sorted().joined(separator: ", "))")
        print("Plan optional products with `pearfy modules plan --add <module>` before applying changes.")
        return 1
    }

    private static func migrate(arguments: [String], projectRoot: URL, environment: [String: String]) async throws -> Int32 {
        guard let action = arguments.first, !action.hasPrefix("--") else {
            var framework: String?
            var profileName = "standard-api"
            var index = 0
            while index < arguments.count {
                let option = arguments[index]
                guard index + 1 < arguments.count else { throw PearfyProjectLifecycleError.missingValue(option) }
                let value = arguments[index + 1]
                switch option {
                case "--framework": framework = try normalizedFramework(value)
                case "--profile": profileName = value
                default: throw PearfyProjectLifecycleError.unknownOption(option)
                }
                index += 2
            }
            let analysis = try analyze(root: projectRoot, declaredFramework: framework)
            let old = try loadManifestIfPresent(root: projectRoot)
            let contract = try mergeWithExisting(analysis, root: projectRoot)
            let profile = try resolveProfile(profileName, decisions: [:])
            let manifest = try makeManifest(
                root: projectRoot,
                mode: old?.project.mode ?? .migrate,
                provenance: old?.provenance ?? "imported",
                origin: moreConfident(old?.origin, contract.origin),
                evidence: contract.evidence,
                contract: contract,
                architecture: old?.architecture ?? PearfyProjectManifest.Architecture(profile: profile.id),
                old: old
            )
            try writeManifest(manifest, contract: contract, root: projectRoot)
            try writeHistory("migration-contract-created", root: projectRoot, references: ["routes:\(contract.routes.count)"])
            print("Contract-first migration initialized; \(contract.routes.count) routes discovered.")
            print("No legacy source code was changed. Map and implement routes, then run per-route E2E verification.")
            return 0
        }

        let options = Array(arguments.dropFirst())
        switch action {
        case "status": return try migrationStatus(options: options, projectRoot: projectRoot)
        case "domain": return try migrationDomain(options: options, projectRoot: projectRoot)
        case "route": return try migrationRoute(options: options, projectRoot: projectRoot)
        case "element": return try migrationElement(options: options, projectRoot: projectRoot)
        case "curl": return try migrationCurl(options: options, projectRoot: projectRoot)
        case "verify": return try await migrationVerify(options: options, projectRoot: projectRoot, environment: environment)
        case "finalize": return try migrationFinalize(options: options, projectRoot: projectRoot)
        default: throw PearfyProjectLifecycleError.usage
        }
    }

    private static func migrationStatus(options: [String], projectRoot: URL) throws -> Int32 {
        guard options.isEmpty || options == ["routes"] || options == ["elements"] else { throw PearfyProjectLifecycleError.usage }
        guard let manifest = try loadManifestIfPresent(root: projectRoot),
              let contract = try loadContractIfPresent(root: projectRoot) else {
            print("INCOMPLETE migration-contract: run `pearfy migrate` to analyze and record the legacy contract")
            return 2
        }
        let progress = PearfyMigrationProgress(routes: contract.routes, elements: contract.elements)
        print("\(contract.origin.framework ?? contract.origin.language ?? "unknown") → Pearfy \(manifest.pearfy.frameworkVersion)")
        print("Routes: discovered \(progress.discovered), contracted \(progress.contracted), mapped \(progress.mapped), implemented \(progress.implemented)")
        print("E2E generated \(progress.e2eGenerated), E2E passing \(progress.e2ePassing), contract closed \(progress.contractClosed), total \(progress.total)")
        print("Conflicts \(progress.conflicts), unsupported \(progress.unsupported), ignored \(progress.ignored)")
        for (kind, counts) in progress.elements.sorted(by: { $0.key < $1.key }) {
            print("\(kind): \(counts.implemented + counts.verified)/\(counts.total) implemented/verified; \(counts.conflicts) conflicts")
        }
        if options == ["routes"] {
            for route in contract.routes {
                print("\(route.state.rawValue)\t\(route.key)\t\(route.id)")
            }
        } else if options == ["elements"] {
            for element in contract.elements {
                print("\(element.state.rawValue)\t\(element.kind.rawValue)\t\(element.id)")
            }
        }
        return 0
    }

    private static func migrationDomain(options: [String], projectRoot: URL) throws -> Int32 {
        guard options.count == 1, isSafeDomain(options[0]) else { throw PearfyProjectLifecycleError.usage }
        var contract = try requiredContract(root: projectRoot)
        let domain = options[0]
        var matched = 0
        for index in contract.routes.indices {
            let firstPathSegment = contract.routes[index].path.split(separator: "/").first.map(String.init)?.lowercased()
            let operationPrefix = contract.routes[index].id.split(separator: ".").first.map(String.init)?.lowercased()
            if firstPathSegment == domain.lowercased() || operationPrefix == domain.lowercased() {
                contract.routes[index].domain = domain
                matched += 1
            }
        }
        guard matched > 0 else { throw PearfyProjectLifecycleError.domainNotFound(domain) }
        try writeContract(contract, root: projectRoot)
        try writeHistory("domain-mapped", root: projectRoot, references: ["domain:\(domain)", "routes:\(matched)"])
        print("Mapped \(matched) contract routes to migration domain \(domain).")
        return 0
    }

    private static func migrationRoute(options: [String], projectRoot: URL) throws -> Int32 {
        guard options.count == 4, options[0] == "--route", options[2] == "--state",
              let state = PearfyMigrationState(rawValue: options[3]), state != .verified else {
            throw PearfyProjectLifecycleError.usage
        }
        var contract = try requiredContract(root: projectRoot)
        let routeKey = canonicalRouteKey(options[1])
        guard let index = contract.routes.firstIndex(where: { $0.key == routeKey }) else {
            throw PearfyProjectLifecycleError.routeNotFound(routeKey)
        }
        let current = contract.routes[index].state
        guard canTransition(from: current, to: state) else {
            throw PearfyProjectLifecycleError.invalidStateTransition(current.rawValue, state.rawValue)
        }
        contract.routes[index].state = state
        try writeContract(contract, root: projectRoot)
        try writeHistory("route-state-changed", root: projectRoot, references: ["route:\(routeKey)", "state:\(state.rawValue)"])
        print("Updated \(routeKey): \(current.rawValue) → \(state.rawValue).")
        return 0
    }

    private static func migrationElement(options: [String], projectRoot: URL) throws -> Int32 {
        guard options.count == 4, options[0] == "--id", options[2] == "--state",
              let state = PearfyMigrationState(rawValue: options[3]),
              state != .verified, state != .e2eGenerated else {
            throw PearfyProjectLifecycleError.usage
        }
        var contract = try requiredContract(root: projectRoot)
        guard let index = contract.elements.firstIndex(where: { $0.id == options[1] }) else {
            throw PearfyProjectLifecycleError.elementNotFound(options[1])
        }
        let current = contract.elements[index].state
        guard canTransition(from: current, to: state) else {
            throw PearfyProjectLifecycleError.invalidStateTransition(current.rawValue, state.rawValue)
        }
        contract.elements[index].state = state
        try writeContract(contract, root: projectRoot)
        try writeHistory("migration-element-state-changed", root: projectRoot, references: ["element:\(contract.elements[index].id)", "state:\(state.rawValue)"])
        print("Updated element \(contract.elements[index].id): \(current.rawValue) → \(state.rawValue).")
        return 0
    }

    private static func migrationCurl(options: [String], projectRoot: URL) throws -> Int32 {
        guard options.count == 2, options[0] == "--route" else { throw PearfyProjectLifecycleError.usage }
        let contract = try requiredContract(root: projectRoot)
        let routeKey = canonicalRouteKey(options[1])
        guard let route = contract.routes.first(where: { $0.key == routeKey }) else {
            throw PearfyProjectLifecycleError.routeNotFound(routeKey)
        }
        let path = MigrationHTTPComparison.curlSafePath(route.path, parameters: route.parameters)
        let query = MigrationHTTPComparison.curlSafeQueryArguments(route.parameters)
        let contentType = route.request.flatMap { request -> String? in
            guard case .object(let mediaTypes) = request else { return nil }
            return mediaTypes.keys.sorted().first
        }
        let body = route.request == nil ? "" : " --data-binary \"@${PEARFY_REQUEST_BODY_FILE}\""
        let contentTypeOption = contentType.map { " --header \"Content-Type: \($0)\"" } ?? ""
        print("# Values are read from environment; no credentials are embedded.")
        print("curl --request \(route.method) \"${PEARFY_LEGACY_URL%/}\(path)\" \(query)\(body)\(contentTypeOption) --header \"Authorization: ${PEARFY_LEGACY_AUTHORIZATION}\"")
        print("curl --request \(route.method) \"${PEARFY_URL%/}\(path)\" \(query)\(body)\(contentTypeOption) --header \"Authorization: ${PEARFY_AUTHORIZATION}\"")
        return 0
    }

    private static func migrationVerify(options: [String], projectRoot: URL, environment: [String: String]) async throws -> Int32 {
        let selection = try parseVerifySelection(options)
        var contract = try requiredContract(root: projectRoot)
        let selectedIndices = contract.routes.indices.filter { index in
            if let route = selection.route { return contract.routes[index].key == route }
            if let domain = selection.domain { return contract.routes[index].domain == domain }
            return true
        }
        guard !selectedIndices.isEmpty else { throw PearfyProjectLifecycleError.routeNotFound(selection.route ?? selection.domain ?? "all") }
        let baseURLs: MigrationHTTPComparison.BaseURLs
        do {
            baseURLs = try MigrationHTTPComparison.baseURLs(environment: environment)
        } catch MigrationHTTPComparisonError.incomplete(let reason) {
            print("INCOMPLETE migration-e2e: \(reason)")
            return 2
        }
        var verified = 0
        var mismatched = 0
        var incomplete = 0
        for index in selectedIndices {
            var route = contract.routes[index]
            do {
                let outcome = try await MigrationHTTPComparison.compare(route: route, baseURLs: baseURLs, environment: environment, allowWrites: selection.allowWrites)
                route.state = outcome.matches ? .verified : .conflict
                contract.routes[index] = route
                try MigrationHTTPComparison.writeResult(outcome, route: route, root: projectRoot)
                if outcome.matches {
                    verified += 1
                    print("VERIFIED \(route.key)")
                } else {
                    mismatched += 1
                    print("MISMATCH \(route.key): \(outcome.mismatches.joined(separator: ", "))")
                }
            } catch MigrationHTTPComparisonError.incomplete(let reason) {
                incomplete += 1
                if route.state == .implemented { route.state = .e2eGenerated }
                contract.routes[index] = route
                print("INCOMPLETE \(route.key): \(reason)")
            } catch MigrationHTTPComparisonError.responseTooLarge {
                incomplete += 1
                print("INCOMPLETE \(route.key): a response exceeded the 2 MiB comparison bound")
            } catch MigrationHTTPComparisonError.transportFailed {
                incomplete += 1
                print("INCOMPLETE \(route.key): an endpoint could not be reached")
            } catch MigrationHTTPComparisonError.invalidResponse {
                incomplete += 1
                print("INCOMPLETE \(route.key): an endpoint returned a non-HTTP response")
            }
        }
        try writeContract(contract, root: projectRoot)
        try writeHistory("e2e-verification", root: projectRoot, references: ["verified:\(verified)", "mismatched:\(mismatched)", "incomplete:\(incomplete)"])
        print("E2E summary: verified \(verified), mismatched \(mismatched), incomplete \(incomplete).")
        if mismatched > 0 { return 1 }
        if incomplete > 0 { return 2 }
        return 0
    }

    private static func migrationFinalize(options: [String], projectRoot: URL) throws -> Int32 {
        guard options.isEmpty else { throw PearfyProjectLifecycleError.usage }
        let contract = try requiredContract(root: projectRoot)
        guard !contract.routes.isEmpty else {
            print("INCOMPLETE migration-finalize: no route contracts were discovered")
            return 2
        }
        let pending = contract.routes.filter { $0.state != .verified && $0.state != .ignored }
        let pendingElements = contract.elements.filter { $0.state != .implemented && $0.state != .verified && $0.state != .ignored }
        guard pending.isEmpty && pendingElements.isEmpty else {
            print("INCOMPLETE migration-finalize: \(pending.count) routes and \(pendingElements.count) structural elements remain open")
            for route in pending.prefix(50) { print("\(route.state.rawValue)\t\(route.key)") }
            for element in pendingElements.prefix(50) { print("\(element.state.rawValue)\t\(element.kind.rawValue)\t\(element.id)") }
            return 2
        }
        try writeHistory("migration-finalized", root: projectRoot, references: ["routes:\(contract.routes.count)", "elements:\(contract.elements.count)"])
        print("PASS migration-finalize: route contracts and required structural elements are closed.")
        return 0
    }

    private static func parseVerifySelection(_ options: [String]) throws -> (route: String?, domain: String?, allowWrites: Bool) {
        var route: String?
        var domain: String?
        var all = false
        var allowWrites = false
        var index = 0
        while index < options.count {
            switch options[index] {
            case "--all":
                guard !all else { throw PearfyProjectLifecycleError.duplicateOption("--all") }
                all = true
                index += 1
            case "--allow-writes":
                guard !allowWrites else { throw PearfyProjectLifecycleError.duplicateOption("--allow-writes") }
                allowWrites = true
                index += 1
            case "--route", "--domain":
                let option = options[index]
                guard index + 1 < options.count else { throw PearfyProjectLifecycleError.missingValue(option) }
                if option == "--route" {
                    guard route == nil else { throw PearfyProjectLifecycleError.duplicateOption(option) }
                    route = canonicalRouteKey(options[index + 1])
                } else {
                    guard domain == nil else { throw PearfyProjectLifecycleError.duplicateOption(option) }
                    domain = options[index + 1]
                }
                index += 2
            default: throw PearfyProjectLifecycleError.unknownOption(options[index])
            }
        }
        guard [route != nil, domain != nil, all].filter({ $0 }).count == 1 else { throw PearfyProjectLifecycleError.usage }
        return (route, domain, allowWrites)
    }

    private static func canTransition(from current: PearfyMigrationState, to next: PearfyMigrationState) -> Bool {
        if current == next { return true }
        if next == .conflict || next == .unsupported || next == .ignored { return true }
        switch current {
        case .discovered: return next == .contracted
        case .contracted: return next == .mapped
        case .mapped: return next == .implemented
        case .implemented: return next == .e2eGenerated
        case .e2eGenerated: return next == .implemented
        case .verified: return false
        case .conflict, .unsupported, .ignored: return next == .discovered || next == .contracted || next == .mapped
        }
    }

    private static func analyze(root: URL, declaredFramework: String?) throws -> PearfyLegacyContractDocument {
        try PearfyLegacyProjectAnalyzer().analyze(projectRoot: root, declaredFramework: declaredFramework)
    }

    private static func mergeWithExisting(_ analyzed: PearfyLegacyContractDocument, root: URL) throws -> PearfyLegacyContractDocument {
        guard let old = try loadContractIfPresent(root: root) else { return analyzed }
        var discovered = Dictionary(uniqueKeysWithValues: analyzed.routes.map { ($0.key, $0) })
        var routes: [PearfyLegacyRouteContract] = []
        for prior in old.routes {
            guard var current = discovered.removeValue(forKey: prior.key) else {
                var retained = prior
                let structuredEvidence = analyzed.evidence.contains { $0.source == "openapi" || $0.source == "spring-source" }
                if structuredEvidence, prior.state == .verified {
                    retained.state = .conflict
                    retained.conflicts.append(PearfyMigrationConflict(
                        field: "route-missing",
                        candidates: ["previously-present", "not-found-in-current-analysis"],
                        evidence: analyzed.evidence
                    ))
                }
                routes.append(retained)
                continue
            }
            current.domain = prior.domain
            current.implementation = prior.implementation
            current.state = prior.state
            let hasOpenAPIEvidence = current.evidence.contains { $0.source == "openapi" }
            if !hasOpenAPIEvidence {
                if current.parameters.isEmpty { current.parameters = prior.parameters }
                if current.request == nil { current.request = prior.request }
                if current.responses.isEmpty { current.responses = prior.responses }
                if current.security.isEmpty { current.security = prior.security }
            }
            current.conflicts = Array(Set(current.conflicts + prior.conflicts)).sorted { $0.field < $1.field }
            let verifiedContractChanged = prior.responses != current.responses
                || prior.request != current.request
                || prior.parameters != current.parameters
                || prior.security != current.security
            if prior.state == .verified && (!current.conflicts.isEmpty || verifiedContractChanged) {
                current.conflicts.append(PearfyMigrationConflict(
                    field: "contract-drift",
                    candidates: ["previously-verified", "source-changed"],
                    evidence: current.evidence
                ))
                current.state = .conflict
            }
            routes.append(current)
        }
        routes.append(contentsOf: discovered.values)
        let elements = mergeElements(previous: old.elements, discovered: analyzed.elements)
        return PearfyLegacyContractDocument(
            origin: moreConfident(old.origin, analyzed.origin),
            routes: routes,
            elements: elements,
            components: old.components.merging(analyzed.components) { _, new in new },
            evidence: old.evidence + analyzed.evidence,
            analyzedFiles: analyzed.analyzedFiles
        )
    }

    private static func mergeElements(
        previous: [PearfyLegacyElementContract],
        discovered: [PearfyLegacyElementContract]
    ) -> [PearfyLegacyElementContract] {
        var currentByID = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
        var merged: [PearfyLegacyElementContract] = []
        for prior in previous {
            guard var current = currentByID.removeValue(forKey: prior.id) else {
                var retained = prior
                let structuredEvidence = discovered.contains(where: { $0.evidence.contains { $0.source == "spring-source" || $0.source == "openapi" } })
                if structuredEvidence && (prior.state == .implemented || prior.state == .verified) {
                    retained.state = .conflict
                    retained.conflicts.append(PearfyMigrationConflict(
                        field: "element-missing",
                        candidates: ["previously-present", "not-found-in-current-analysis"],
                        evidence: discovered.flatMap(\.evidence)
                    ))
                }
                merged.append(retained)
                continue
            }
            current.domain = prior.domain
            current.state = prior.state
            for (key, value) in prior.attributes {
                if let currentValue = current.attributes[key], currentValue != value,
                   (prior.state == .implemented || prior.state == .verified) {
                    current.conflicts.append(PearfyMigrationConflict(
                        field: "attributes.\(key)",
                        candidates: ["previously-recorded", "current-source"],
                        evidence: current.evidence + prior.evidence
                    ))
                    current.state = .conflict
                } else if current.attributes[key] == nil {
                    current.attributes[key] = value
                }
            }
            current.evidence = Array(Set(current.evidence + prior.evidence)).sorted {
                ($0.source, $0.path ?? "", $0.detail) < ($1.source, $1.path ?? "", $1.detail)
            }
            current.conflicts = Array(Set(current.conflicts + prior.conflicts)).sorted { $0.field < $1.field }
            merged.append(current)
        }
        merged.append(contentsOf: currentByID.values)
        return merged.sorted { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
    }

    private static func makeManifest(
        root: URL,
        mode: PearfyMigrationEntryMode,
        provenance: String,
        origin: PearfyMigrationOrigin,
        evidence: [PearfyMigrationEvidence],
        contract: PearfyLegacyContractDocument,
        architecture: PearfyProjectManifest.Architecture,
        explicitName: String? = nil,
        old: PearfyProjectManifest? = nil
    ) throws -> PearfyProjectManifest {
        let modules = installedModules(root: root)
        var evidenceMap = old?.evidence ?? [:]
        evidenceMap["origin.framework"] = evidence
        return PearfyProjectManifest(
            project: .init(name: explicitName ?? old?.project.name ?? projectName(root: root), mode: mode),
            provenance: provenance,
            origin: origin,
            evidence: evidenceMap,
            architecture: architecture,
            migration: .init(status: PearfyMigrationProgress(routes: contract.routes, elements: contract.elements)),
            modules: enabledProducts(for: modules)
        )
    }

    private static func writeManifest(_ manifest: PearfyProjectManifest, contract: PearfyLegacyContractDocument, root: URL) throws {
        try ensureSafeDirectory(root.appendingPathComponent(".pearfy", isDirectory: true))
        let manifestURL = root.appendingPathComponent(manifestName)
        let architectureURL = root.appendingPathComponent(".pearfy/architecture.yml")
        var updatedManifest = manifest
        updatedManifest.migration.status = PearfyMigrationProgress(routes: contract.routes, elements: contract.elements)
        updatedManifest.modules = enabledProducts(for: installedModules(root: root))
        try writeDocuments([
            (manifestURL, try PearfyMigrationDocumentStore.encode(updatedManifest)),
            (root.appendingPathComponent(contractRelativePath), try PearfyMigrationDocumentStore.encode(contract)),
            (architectureURL, try PearfyMigrationDocumentStore.encode(updatedManifest.architecture))
        ], root: root)
    }

    private static func writeContract(_ contract: PearfyLegacyContractDocument, root: URL) throws {
        try ensureSafeDirectory(root.appendingPathComponent(".pearfy", isDirectory: true))
        try ensureSafeDirectory(root.appendingPathComponent(".pearfy/migration", isDirectory: true))
        let url = root.appendingPathComponent(contractRelativePath)
        let manifestURL = root.appendingPathComponent(manifestName)
        var documents: [(URL, Data)] = [(url, try PearfyMigrationDocumentStore.encode(contract))]
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            var manifest = try PearfyMigrationDocumentStore.load(PearfyProjectManifest.self, from: manifestURL)
            manifest.migration.status = PearfyMigrationProgress(routes: contract.routes, elements: contract.elements)
            documents.append((manifestURL, try PearfyMigrationDocumentStore.encode(manifest)))
        }
        try writeDocuments(documents, root: root)
    }

    private static func loadManifestIfPresent(root: URL) throws -> PearfyProjectManifest? {
        let url = root.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try ensureRegularOrMissingFile(url)
        return try PearfyMigrationDocumentStore.load(PearfyProjectManifest.self, from: url)
    }

    private static func loadContractIfPresent(root: URL) throws -> PearfyLegacyContractDocument? {
        let url = root.appendingPathComponent(contractRelativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try ensureRegularOrMissingFile(url)
        return try PearfyMigrationDocumentStore.load(PearfyLegacyContractDocument.self, from: url)
    }

    private static func requiredContract(root: URL) throws -> PearfyLegacyContractDocument {
        guard let contract = try loadContractIfPresent(root: root) else { throw PearfyProjectLifecycleError.contractRequired }
        return contract
    }

    private static func installedModules(root: URL) -> Set<String> {
        if let manager = try? PearfyModuleManager(),
           let selected = try? manager.doctor(projectRoot: root) {
            return Set(selected)
        }
        let packageURL = root.appendingPathComponent("Package.swift")
        guard let data = try? Data(contentsOf: packageURL), data.count <= 2 * 1_024 * 1_024,
              let manifest = String(data: data, encoding: .utf8),
              let manager = try? PearfyModuleManager() else { return [] }
        var products: Set<String> = []
        for module in manager.availableModules() {
            for product in module.products where manifest.contains("name: \"\(product)\"") || manifest.contains("import \(product)") {
                products.insert(product)
            }
        }
        var selected: Set<String> = []
        for module in manager.availableModules() where !Set(module.products).isDisjoint(with: products) {
            selected.insert(module.id)
        }
        return selected
    }

    private static func selectedModuleIDs(root: URL) throws -> Set<String> {
        if let manager = try? PearfyModuleManager(),
           let selected = try? manager.doctor(projectRoot: root) { return Set(selected) }
        return installedModules(root: root)
    }

    private static func enabledProducts(for moduleIDs: Set<String>) -> [String: Bool] {
        guard let manager = try? PearfyModuleManager() else { return [:] }
        let productNames = manager.availableModules()
            .filter { moduleIDs.contains($0.id) }
            .flatMap(\.products)
        return Dictionary(uniqueKeysWithValues: Set(productNames).sorted().map { ($0, true) })
    }

    private static func isPearfyProject(root: URL) -> Bool {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(manifestName).path) { return true }
        guard let manager = try? PearfyModuleManager() else { return false }
        let packageURL = root.appendingPathComponent("Package.swift")
        if let data = try? Data(contentsOf: packageURL), data.count <= 2 * 1_024 * 1_024,
           let text = String(data: data, encoding: .utf8), manager.availableModules().contains(where: { module in
               module.products.contains(where: { text.contains($0) })
           }) { return true }
        return false
    }

    private static func writeHistory(_ event: String, root: URL, references: [String]) throws {
        struct Entry: Encodable {
            let timestamp: String
            let event: String
            let cli: String
            let references: [String]
        }
        let directory = root.appendingPathComponent(".pearfy", isDirectory: true)
        try ensureSafeDirectory(directory)
        let url = directory.appendingPathComponent("history.jsonl")
        try ensureRegularOrMissingFile(url)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber, size.intValue > 1_048_576 {
            throw PearfyProjectLifecycleError.historyLimit
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let entry = Entry(timestamp: ISO8601DateFormatter().string(from: Date()), event: event, cli: cliVersion, references: references.sorted())
        var data = try encoder.encode(entry)
        data.append(0x0a)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private static func installProfile(_ profile: Profile, into root: URL) throws {
        let manager = try PearfyModuleManager()
        var selected = ["http"]
        for module in profile.moduleIDs.filter({ $0 != "http" }) {
            let plan = try manager.planAdding(module, to: selected)
            try manager.apply(plan, to: root)
            selected = plan.plannedModules
        }
    }

    private static func resolveProfile(_ input: String, decisions: [String: PearfyMigrationJSONValue]) throws -> Profile {
        let normalized = input.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
        switch normalized {
        case "standard", "api", "standard-api":
            return Profile(id: "standard-api", moduleIDs: ["http"], decisions: decisions)
        case "financial", "transactional", "financial-transactional":
            return Profile(id: "financial-transactional", moduleIDs: ["http", "transactions", "data", "postgres", "security", "observability"], decisions: decisions)
        case "social", "community", "social-community":
            return Profile(id: "social-community", moduleIDs: ["http", "data", "postgres", "security", "social", "social-postgres", "observability"], decisions: decisions)
        case "realtime", "game", "realtime-game-server":
            return Profile(id: "realtime-game-server", moduleIDs: ["http", "messaging", "redis", "observability", "security"], decisions: decisions)
        case "iot", "iot-backend":
            return Profile(id: "iot-backend", moduleIDs: ["http", "messaging", "redis", "security", "observability"], decisions: decisions)
        case "high-traffic", "high-traffic-platform":
            return Profile(id: "high-traffic-platform", moduleIDs: ["http", "cache", "redis", "messaging", "cloud", "observability", "security"], decisions: decisions)
        case "custom":
            return Profile(id: "custom", moduleIDs: ["http"], decisions: decisions)
        default: throw PearfyProjectLifecycleError.unknownProfile(input)
        }
    }

    private static func normalizeArchitectureStyle(_ value: String?) -> String {
        guard let value else { return "clean" }
        let normalized = value.lowercased()
        return ["clean", "modular", "layered", "hexagonal"].contains(normalized) ? normalized : "clean"
    }

    private static func normalizedFramework(_ value: String) throws -> String {
        let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 100,
              normalized.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else {
            throw PearfyProjectLifecycleError.invalidFramework
        }
        return normalized
    }

    private static func projectName(root: URL) -> String {
        if let data = try? Data(contentsOf: root.appendingPathComponent("Package.swift")),
           let text = String(data: data, encoding: .utf8),
           let range = text.range(of: #"name\s*:\s*\"([^\"]+)\""#, options: .regularExpression) {
            let declaration = String(text[range])
            if let first = declaration.firstIndex(of: "\""), let last = declaration[declaration.index(after: first)...].firstIndex(of: "\"") {
                return String(declaration[declaration.index(after: first)..<last])
            }
        }
        return root.lastPathComponent
    }

    private static func moreConfident(_ old: PearfyMigrationOrigin?, _ new: PearfyMigrationOrigin) -> PearfyMigrationOrigin {
        guard let old else { return new }
        let rank: [PearfyEvidenceConfidence: Int] = [.low: 0, .medium: 1, .high: 2]
        return rank[old.confidence, default: 0] > rank[new.confidence, default: 0] ? old : new
    }

    private static func resolvePath(_ path: String?, relativeTo root: URL) -> URL? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
    }

    private static func isSafeDecisionKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 64 && key.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func isSafeDomain(_ domain: String) -> Bool {
        !domain.isEmpty && domain.utf8.count <= 64 && domain.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func canonicalRouteKey(_ value: String) -> String {
        guard let separator = value.firstIndex(where: { $0.isWhitespace }) else { return value.uppercased() }
        let method = value[..<separator].uppercased()
        let path = value[value.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        return "\(method) \(path)"
    }

    private static func ensureSafeDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw PearfyProjectLifecycleError.unsafePath(url.path)
            }
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func ensureRegularOrMissingFile(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PearfyProjectLifecycleError.unsafePath(url.path)
        }
    }

    private static func writeDocuments(_ documents: [(URL, Data)], root: URL) throws {
        let rootURL = root.standardizedFileURL
        var previous: [(URL, Data?)] = []
        for (url, _) in documents {
            let normalized = url.standardizedFileURL
            guard normalized.path.hasPrefix(rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/") else {
                throw PearfyProjectLifecycleError.unsafePath(url.path)
            }
            try ensureSafeParent(of: normalized, root: rootURL)
            try ensureRegularOrMissingFile(normalized)
            let oldData = FileManager.default.fileExists(atPath: normalized.path)
                ? try Data(contentsOf: normalized, options: .mappedIfSafe)
                : nil
            previous.append((normalized, oldData))
        }
        do {
            for (url, data) in documents {
                try data.write(to: url.standardizedFileURL, options: .atomic)
            }
        } catch {
            for (url, oldData) in previous {
                if let oldData { try? oldData.write(to: url, options: .atomic) }
                else { try? FileManager.default.removeItem(at: url) }
            }
            throw error
        }
    }

    private static func ensureSafeParent(of file: URL, root: URL) throws {
        let relativeParent = file.deletingLastPathComponent().path
            .dropFirst(root.path.hasSuffix("/") ? root.path.count : root.path.count + 1)
        var current = root
        for component in relativeParent.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            if FileManager.default.fileExists(atPath: current.path) {
                let values = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw PearfyProjectLifecycleError.unsafePath(current.path)
                }
            } else {
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
    }
}

private enum PearfyProjectLifecycleError: Error, Sendable, CustomStringConvertible {
    case usage
    case unknownOption(String)
    case missingValue(String)
    case duplicateOption(String)
    case invalidDecision
    case unknownProfile(String)
    case invalidFramework
    case compatibleProjectRequired(String)
    case pearfyProjectRequired
    case manifestRequired
    case contractRequired
    case routeNotFound(String)
    case elementNotFound(String)
    case domainNotFound(String)
    case invalidStateTransition(String, String)
    case historyLimit
    case unsafePath(String)

    var description: String {
        switch self {
        case .usage:
            "Usage: pearfy init <name> [--profile <profile>] [--path <dir>] | adopt|baseline|inspect|sync|doctor [options] | migrate [status|domain|route|element|verify|curl|finalize]"
        case .unknownOption(let option): "unknown option: \(option)"
        case .missingValue(let option): "missing value for \(option)"
        case .duplicateOption(let option): "option provided more than once: \(option)"
        case .invalidDecision: "architecture decisions use bounded key=value pairs"
        case .unknownProfile(let profile): "unknown architecture profile '\(profile)'"
        case .invalidFramework: "framework name must contain only ASCII letters, digits, '.' or '-'"
        case .compatibleProjectRequired(let path): "project at \(path) has no Package.swift to adopt"
        case .pearfyProjectRequired: "no existing Pearfy project was detected; use `pearfy migrate` for a legacy backend"
        case .manifestRequired: "pearfy.project.yml is missing; run `pearfy baseline`, `pearfy adopt`, or `pearfy migrate`"
        case .contractRequired: "canonical Legacy Contract is missing; run `pearfy migrate`"
        case .routeNotFound(let route): "route or domain not found in the Legacy Contract: \(route)"
        case .elementNotFound(let element): "structural element not found in the Legacy Contract: \(element)"
        case .domainNotFound(let domain): "no route could be assigned to migration domain '\(domain)'"
        case .invalidStateTransition(let from, let to): "migration route state cannot move from \(from) to \(to)"
        case .historyLimit: "migration history exceeds the 1 MiB append limit"
        case .unsafePath(let path): "refusing to follow a symlink or non-directory migration path: \(path)"
        }
    }
}

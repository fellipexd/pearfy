import Foundation
import PearfyData
import PearfyPostgres
import PearfyPopulateCore
import PearfyPopulatePostgres

public enum PearfyPopulateCommand {
    private static let adjacentPearfyMigrationIDs: Set<String> = [
        "embersquare-social-content-v1-idempotency",
        "social-v1-01-actors",
        "social-v1-02-actor-handle-check",
        "social-v1-03-follows",
        "social-v1-04-blocks"
    ]

    public static func run(
        arguments: [String],
        projectRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> Int32 {
        guard let command = arguments.first else { throw PopulateCLIError.usage }
        let options = try CommandOptions(arguments: Array(arguments.dropFirst()))
        try options.validate(for: command)
        switch command {
        case "preview":
            let plan = try loadPlan(options.required("plan"), projectRoot: projectRoot)
            printJSON(PlanPreview(plan: plan))
            return 0
        case "status":
            let runID = try options.required("run")
            let registry = FilePopulateRunRegistry(directory: runDirectory(projectRoot))
            guard let state = try await registry.load(runID: runID) else { throw PopulateCLIError.runNotFound(runID) }
            printJSON(state)
            return 0
        case "report":
            let runID = try options.required("run")
            let registry = FilePopulateRunRegistry(directory: runDirectory(projectRoot))
            guard let state = try await registry.load(runID: runID) else { throw PopulateCLIError.runNotFound(runID) }
            let plan = try loadPlanByID(runID, projectRoot: projectRoot)
            printJSON(PopulateRunReport(
                state: state,
                plan: plan,
                metricComparison: "PearfyMetric is not installed; no benchmark comparison was performed."
            ))
            return state.status == .partial || state.status == .cancelled ? 1 : 0
        case "inspect", "profile", "plan", "run", "verify", "schema", "approve":
            return try await withDatabase(options: options, environment: environment) { database, targetEnvironment, host in
                let snapshot = try await PearfyPostgresPopulateAdapter.inspect(database: database)
                try PopulateSafetyGuard.validate(
                    environment: targetEnvironment,
                    host: host,
                    database: snapshot.databaseName,
                    allowRemoteLocal: environment["PEARFY_POPULATE_ALLOW_REMOTE_LOCAL"] == "1",
                    allowStaging: environment["PEARFY_POPULATE_ALLOW_STAGING"] == "1"
                )
                let adapter = PearfyPostgresPopulateAdapter(database: database, snapshot: snapshot)

                switch command {
                case "inspect":
                    printJSON(inspection(snapshot: snapshot, projectRoot: projectRoot, environment: targetEnvironment))
                    return 0
                case "schema":
                    guard options.positional.isEmpty || options.positional == ["check"] else { throw PopulateCLIError.usage }
                    try await validateMigrationHistory(projectRoot: projectRoot, snapshot: snapshot, database: database)
                    let desiredURL = projectRoot.appendingPathComponent(".pearfy/schema.json")
                    guard FileManager.default.fileExists(atPath: desiredURL.path) else {
                        printJSON([
                            "compatible": false,
                            "reason": "No .pearfy/schema.json model manifest is configured; live schema and migration history were inspected, but model drift cannot be certified."
                        ] as [String: Any])
                        return 2
                    }
                    let result = try await reconcileDesiredSchema(projectRoot: projectRoot, snapshot: snapshot, database: database)
                    printJSON(result)
                    return result.isCompatible ? 0 : 1
                case "profile":
                    guard targetEnvironment == .local,
                          options.flags.contains("sample-local") else { throw PopulateCLIError.profileRequiresLocalSample }
                    let table = try snapshot.table(named: options.required("table"))
                    let profile = try await adapter.profile(table)
                    printJSON(profile)
                    return 0
                case "plan":
                    try await validateMigrationHistory(projectRoot: projectRoot, snapshot: snapshot, database: database)
                    let reconciliation = try await reconcileDesiredSchema(projectRoot: projectRoot, snapshot: snapshot, database: database)
                    guard reconciliation.isCompatible else { throw PopulateSchemaError.schemaDrift(reconciliation.differences) }
                    let request = try parsePlanRequest(options: options, environment: targetEnvironment, projectRoot: projectRoot)
                    let table = try snapshot.table(named: request.table)
                    let metrics = try await adapter.size(of: table)
                    let sizeMode = request.sizeMode ?? .total
                    let uniqueBases = try await adapter.integerUniqueBases(for: table)
                    let resolvedRequest = try PopulatePlanRequest(
                        table: request.table,
                        environment: targetEnvironment,
                        seed: request.seed,
                        requestedRows: request.requestedRows,
                        targetSizeBytes: request.targetSizeBytes,
                        sizeMode: request.sizeMode,
                        limits: request.limits,
                        integerUniqueBases: uniqueBases
                    )
                    let plan = try PopulatePlanner.makePlan(
                        request: resolvedRequest,
                        snapshot: snapshot,
                        currentRowCount: metrics.rowCount,
                        currentSizeBytes: metrics.bytes(for: sizeMode),
                        estimatedBytesPerRow: metrics.rowCount > 0 && metrics.bytes(for: sizeMode) > 0
                            ? max(1, metrics.bytes(for: sizeMode) / metrics.rowCount)
                            : nil
                    )
                    try adapter.validateWritable(table, plannedRows: plan.rowCount)
                    let path = try savePlan(plan, projectRoot: projectRoot)
                    printJSON(PlanPreview(plan: plan, planPath: path.path))
                    return 0
                case "approve":
                    try await validateMigrationHistory(projectRoot: projectRoot, snapshot: snapshot, database: database)
                    let reconciliation = try await reconcileDesiredSchema(projectRoot: projectRoot, snapshot: snapshot, database: database)
                    guard reconciliation.isCompatible else { throw PopulateSchemaError.schemaDrift(reconciliation.differences) }
                    let plan = try loadPlan(options.required("plan"), projectRoot: projectRoot)
                    guard plan.environment == targetEnvironment else { throw PopulateCLIError.environmentMismatch }
                    let actualFingerprint = try snapshot.fingerprint()
                    guard actualFingerprint == plan.schemaFingerprint else {
                        throw PopulateExecutionError.schemaChanged(expected: plan.schemaFingerprint, actual: actualFingerprint)
                    }
                    let table = try snapshot.table(named: plan.table)
                    try adapter.validateWritable(table, plannedRows: plan.rowCount)
                    FileHandle.standardError.write(Data("Approve database '\(snapshot.databaseName)' table '\(table.qualifiedName)' for plan \(plan.planHash)? Type 'approve \(plan.planHash)' to confirm: ".utf8))
                    guard let confirmation = readLine() else { throw PopulateCLIError.approvalInputRequired }
                    let token = try PopulateApprovalStore(projectRoot: projectRoot).issue(plan: plan, confirmation: confirmation)
                    printJSON(["planHash": plan.planHash, "approvalToken": token, "expiresInSeconds": 604_800] as [String: Any])
                    return 0
                case "run":
                    try await validateMigrationHistory(projectRoot: projectRoot, snapshot: snapshot, database: database)
                    let reconciliation = try await reconcileDesiredSchema(projectRoot: projectRoot, snapshot: snapshot, database: database)
                    guard reconciliation.isCompatible else { throw PopulateSchemaError.schemaDrift(reconciliation.differences) }
                    let plan = try loadPlan(options.required("plan"), projectRoot: projectRoot)
                    guard plan.environment == targetEnvironment else { throw PopulateCLIError.environmentMismatch }
                    let approval = try options.required("approve-plan-hash")
                    let table = try snapshot.table(named: plan.table)
                    let metrics = try await adapter.size(of: table)
                    guard try snapshot.fingerprint() == plan.schemaFingerprint else {
                        throw PopulateExecutionError.schemaChanged(expected: plan.schemaFingerprint, actual: try snapshot.fingerprint())
                    }
                    try adapter.validateWritable(table, plannedRows: plan.rowCount)
                    try validateDiskCapacity(plan: plan, currentSize: metrics.bytes(for: plan.sizeMode ?? .total), projectRoot: projectRoot)
                    let approvalToken: String?
                    if options.flags.contains("approval-token-stdin") {
                        guard options.values["approval-token"] == nil,
                              let token = readLine(), !token.isEmpty else {
                            throw PopulateCLIError.approvalInputRequired
                        }
                        approvalToken = token
                    } else {
                        approvalToken = options.values["approval-token"]
                    }
                    if let approvalToken {
                        try PopulateApprovalStore(projectRoot: projectRoot).validate(
                            token: approvalToken,
                            plan: plan,
                            environment: targetEnvironment,
                            databaseName: snapshot.databaseName
                        )
                    }
                    let registry = FilePopulateRunRegistry(directory: runDirectory(projectRoot))
                    let state = try await PopulateRunner().execute(
                        plan: plan,
                        approvalHash: approval,
                        currentSchemaFingerprint: try snapshot.fingerprint(),
                        store: adapter,
                        registry: registry,
                        currentSizeBytes: metrics.bytes(for: plan.sizeMode ?? .total)
                    )
                    printJSON(state)
                    return state.status == .partial || state.status == .cancelled ? 1 : 0
                case "verify":
                    try await validateMigrationHistory(projectRoot: projectRoot, snapshot: snapshot, database: database)
                    let reconciliation = try await reconcileDesiredSchema(projectRoot: projectRoot, snapshot: snapshot, database: database)
                    guard reconciliation.isCompatible else { throw PopulateSchemaError.schemaDrift(reconciliation.differences) }
                    let runID = try options.required("run")
                    let plan = try loadPlanByID(runID, projectRoot: projectRoot)
                    guard plan.environment == targetEnvironment else { throw PopulateCLIError.environmentMismatch }
                    let registry = FilePopulateRunRegistry(directory: runDirectory(projectRoot))
                    guard let state = try await registry.load(runID: runID) else { throw PopulateCLIError.runNotFound(runID) }
                    guard try snapshot.fingerprint() == state.schemaFingerprint else {
                        throw PopulateExecutionError.schemaChanged(expected: state.schemaFingerprint, actual: try snapshot.fingerprint())
                    }
                    let result = try await adapter.verify(plan)
                    printJSON(VerificationReport(state: state, verification: result))
                    return result.sizeReached ? 0 : 1
                default:
                    throw PopulateCLIError.usage
                }
            }
        default:
            throw PopulateCLIError.unknownCommand(command)
        }
    }

    private struct RequestValues {
        let table: String
        let seed: UInt64
        let requestedRows: Int?
        let targetSizeBytes: Int64?
        let sizeMode: PopulateSizeMode?
        let limits: PopulateExecutionLimits
    }

    private static func withDatabase(
        options: CommandOptions,
        environment: [String: String],
        operation: (any SQLDatabase, PopulateEnvironment, String) async throws -> Int32
    ) async throws -> Int32 {
        let target = try parseEnvironment(options.required("environment"))
        let host = environment["PEARFY_POPULATE_PGHOST"] ?? environment["PGHOST"] ?? "127.0.0.1"
        let portString = environment["PEARFY_POPULATE_PGPORT"] ?? environment["PGPORT"] ?? "5432"
        guard let port = Int(portString) else { throw PopulateCLIError.invalidInteger("PostgreSQL port") }
        let username = environment["PEARFY_POPULATE_PGUSER"] ?? environment["PGUSER"] ?? environment["USER"] ?? "postgres"
        let password = environment["PEARFY_POPULATE_PGPASSWORD"] ?? environment["PGPASSWORD"]
        let databaseName = environment["PEARFY_POPULATE_DATABASE"] ?? environment["PGDATABASE"]
        let tls: PearfyPostgresTLSMode = target == .staging ? .required : .disabled
        let settings = try PearfyPostgresConnectionSettings(
            host: host,
            port: port,
            username: username,
            password: password,
            database: databaseName,
            tls: tls,
            maximumConnections: 4
        )
        let database = PearfyPostgresDatabase(settings: settings)
        try await database.start()
        do {
            let status = try await operation(database, target, host)
            try await database.stop()
            return status
        } catch {
            try? await database.stop()
            throw error
        }
    }

    private static func parsePlanRequest(
        options: CommandOptions,
        environment: PopulateEnvironment,
        projectRoot: URL
    ) throws -> RequestValues {
        var table = options.values["table"]
        var seed = try unsignedInteger(options.values["seed"], name: "seed", default: 1)
        var requestedRows = try integer(options.values["rows"], name: "rows")
        var targetSize = try options.values["target-size"].map(parseSize)
        var sizeMode = try options.values["size-mode"].map { value in
            guard let mode = PopulateSizeMode(rawValue: value) else { throw PopulateCLIError.invalidSizeMode(value) }
            return mode
        }
        var maxRows = try integer(options.values["max-rows"], name: "max-rows", default: 100_000) ?? 100_000
        var batchRows = try integer(options.values["max-batch-rows"], name: "max-batch-rows", default: 1_000) ?? 1_000
        var maxDuration = try integer(options.values["max-duration"], name: "max-duration", default: 900) ?? 900
        var minimumFreeDisk: Int64 = try options.values["min-free-disk"].map(parseSize) ?? 1_073_741_824

        if let recipePath = options.values["recipe"] {
            let url = URL(fileURLWithPath: recipePath, relativeTo: projectRoot).standardizedFileURL
            let recipe = try PopulateRecipe(contents: String(contentsOf: url, encoding: .utf8))
            if let recipeEnvironment = recipe.environment, recipeEnvironment != environment {
                throw PopulateCLIError.recipeEnvironmentMismatch
            }
            table = table ?? recipe.table
            seed = try unsignedInteger(options.values["seed"] ?? recipe.seed.map(String.init), name: "seed", default: seed)
            requestedRows = requestedRows ?? recipe.rows
            targetSize = targetSize ?? recipe.targetSize
            sizeMode = sizeMode ?? recipe.sizeMode
            maxRows = try integer(options.values["max-rows"] ?? recipe.maxRows.map(String.init), name: "max-rows", default: maxRows) ?? maxRows
            batchRows = try integer(options.values["max-batch-rows"] ?? recipe.maxBatchRows.map(String.init), name: "max-batch-rows", default: batchRows) ?? batchRows
            maxDuration = try integer(options.values["max-duration"] ?? recipe.maxDurationSeconds.map(String.init), name: "max-duration", default: maxDuration) ?? maxDuration
            minimumFreeDisk = try options.values["min-free-disk"].map(parseSize) ?? recipe.minimumFreeDiskBytes ?? minimumFreeDisk
        }
        guard let table, !table.isEmpty else { throw PopulateCLIError.missing("table or recipe") }
        let limits = try PopulateExecutionLimits(
            maxRows: maxRows,
            maxDurationSeconds: maxDuration,
            maxBatchRows: batchRows,
            minimumFreeDiskBytes: minimumFreeDisk
        )
        return RequestValues(
            table: table,
            seed: seed,
            requestedRows: requestedRows,
            targetSizeBytes: targetSize,
            sizeMode: sizeMode,
            limits: limits
        )
    }

    private static func parseEnvironment(_ value: String) throws -> PopulateEnvironment {
        guard let environment = PopulateEnvironment(rawValue: value) else {
            throw PopulateCLIError.invalidEnvironment(value)
        }
        return environment
    }

    fileprivate static func parseSize(_ value: String) throws -> Int64 {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let suffixes: [(String, Double)] = [
            ("GIB", 1_073_741_824), ("GB", 1_000_000_000),
            ("MIB", 1_048_576), ("MB", 1_000_000),
            ("KIB", 1_024), ("KB", 1_000), ("B", 1)
        ]
        for (suffix, multiplier) in suffixes where normalized.hasSuffix(suffix) {
            let number = String(normalized.dropLast(suffix.count))
            guard let amount = Double(number), amount > 0,
                  amount * multiplier < Double(Int64.max) else { throw PopulateCLIError.invalidSize(value) }
            return Int64((amount * multiplier).rounded(.up))
        }
        guard let bytes = Int64(normalized), bytes > 0 else { throw PopulateCLIError.invalidSize(value) }
        return bytes
    }

    private static func integer(_ value: String?, name: String, default defaultValue: Int? = nil) throws -> Int? {
        guard let value else { return defaultValue }
        guard let parsed = Int(value) else { throw PopulateCLIError.invalidInteger(name) }
        return parsed
    }

    private static func unsignedInteger(_ value: String?, name: String, default defaultValue: UInt64) throws -> UInt64 {
        guard let value else { return defaultValue }
        guard let parsed = UInt64(value) else { throw PopulateCLIError.invalidInteger(name) }
        return parsed
    }

    private static func savePlan(_ plan: PopulatePlan, projectRoot: URL) throws -> URL {
        let directory = projectRoot.appendingPathComponent(".pearfy/populate/plans", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = directory.appendingPathComponent("\(plan.id).json")
        try (encoder.encode(plan) + Data([0x0a])).write(to: url, options: .atomic)
        return url
    }

    private static func loadPlan(_ path: String, projectRoot: URL) throws -> PopulatePlan {
        let url = URL(fileURLWithPath: path, relativeTo: projectRoot).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw PopulateCLIError.fileNotFound(url.path) }
        do { return try JSONDecoder().decode(PopulatePlan.self, from: Data(contentsOf: url)) }
        catch { throw PopulateCLIError.invalidPlan(url.path) }
    }

    private static func loadPlanByID(_ planID: String, projectRoot: URL) throws -> PopulatePlan {
        guard planID.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }) else {
            throw PopulateCLIError.runNotFound(planID)
        }
        let url = projectRoot.appendingPathComponent(".pearfy/populate/plans/\(planID).json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw PopulateCLIError.fileNotFound(url.path) }
        do { return try JSONDecoder().decode(PopulatePlan.self, from: Data(contentsOf: url)) }
        catch { throw PopulateCLIError.invalidPlan(url.path) }
    }

    private static func runDirectory(_ projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(".pearfy/populate/runs", isDirectory: true)
    }

    private static func validateDiskCapacity(plan: PopulatePlan, currentSize: Int64, projectRoot: URL) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: projectRoot.path)
        let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard available >= plan.limits.minimumFreeDiskBytes else {
            throw PopulateCLIError.insufficientDisk(available: available, required: plan.limits.minimumFreeDiskBytes)
        }
        if let target = plan.targetSizeBytes {
            let estimatedGrowth = max(0, target - currentSize)
            guard estimatedGrowth <= available - plan.limits.minimumFreeDiskBytes else {
                throw PopulateCLIError.insufficientDisk(available: available, required: estimatedGrowth + plan.limits.minimumFreeDiskBytes)
            }
        }
    }

    private static func loadMigrations(projectRoot: URL) throws -> [SQLMigration] {
        guard let directory = migrationDirectory(projectRoot) else { return [] }
        return try SQLMigrationCatalog(directory: directory).migrations
    }

    private static func reconcileDesiredSchema(
        projectRoot: URL,
        snapshot: PopulateSchemaSnapshot,
        database: any SQLDatabase
    ) async throws -> PopulateSchemaReconciliation {
        let schemaURL = projectRoot.appendingPathComponent(".pearfy/schema.json")
        guard FileManager.default.fileExists(atPath: schemaURL.path) else {
            throw PopulateCLIError.modelSchemaMissing
        }
        let desired: SchemaIR
        do { desired = try JSONDecoder().decode(SchemaIR.self, from: Data(contentsOf: schemaURL)) }
        catch { throw PopulateCLIError.invalidModelSchema(schemaURL.path) }
        let migrations = try loadMigrations(projectRoot: projectRoot)
        let reconciliationSnapshot = try await snapshotRecognizingLegacyBaseline(
            snapshot,
            migrations: migrations,
            database: database
        )
        return try PopulateSchemaReconciler.reconcile(
            desired: desired,
            migrations: migrations,
            actual: reconciliationSnapshot
        )
    }

    private static func migrationDirectory(_ projectRoot: URL) -> URL? {
        ["Migrations", ".pearfy/migrations"].map { projectRoot.appendingPathComponent($0, isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func validateMigrationHistory(
        projectRoot: URL,
        snapshot: PopulateSchemaSnapshot,
        database: any SQLDatabase
    ) async throws {
        let declared = try loadMigrations(projectRoot: projectRoot)
        if try await matchesLegacyJavaBaseline(snapshot, migrations: declared, database: database) != nil {
            return
        }
        let applied = Dictionary(uniqueKeysWithValues: snapshot.appliedMigrations.map { ($0.id, $0.checksum) })
        if migrationDirectory(projectRoot) == nil && !snapshot.appliedMigrations.isEmpty {
            throw PopulateCLIError.migrationSourcesMissing
        }
        var differences: [PopulateSchemaDifference] = []
        for migration in declared {
            guard let checksum = applied[migration.id] else {
                differences.append(.init(path: "migrations.\(migration.id)", expected: migration.checksum, actual: "not applied"))
                continue
            }
            if checksum != migration.checksum {
                differences.append(.init(path: "migrations.\(migration.id)", expected: migration.checksum, actual: checksum ?? "missing checksum"))
            }
        }
        let declaredIDs = Set(declared.map(\.id))
        for migration in snapshot.appliedMigrations where !declaredIDs.contains(migration.id) {
            differences.append(.init(path: "migrations.\(migration.id)", expected: "declared", actual: "unknown applied migration"))
        }
        if !differences.isEmpty { throw PopulateSchemaError.schemaDrift(differences) }
    }

    private static func snapshotRecognizingLegacyBaseline(
        _ snapshot: PopulateSchemaSnapshot,
        migrations: [SQLMigration],
        database: any SQLDatabase
    ) async throws -> PopulateSchemaSnapshot {
        guard let baseline = try await matchesLegacyJavaBaseline(snapshot, migrations: migrations, database: database) else {
            return snapshot
        }
        return PopulateSchemaSnapshot(
            databaseName: snapshot.databaseName,
            serverAddress: snapshot.serverAddress,
            serverPort: snapshot.serverPort,
            tables: snapshot.tables,
            appliedMigrations: [PopulateAppliedMigration(id: baseline.id, checksum: baseline.checksum)]
        )
    }

    /// Treats a clean legacy `schema_migrations` baseline as the model-generated
    /// snapshot's predecessor without inserting/adopting rows in either journal.
    private static func matchesLegacyJavaBaseline(
        _ snapshot: PopulateSchemaSnapshot,
        migrations: [SQLMigration],
        database: any SQLDatabase
    ) async throws -> SQLMigration? {
        guard snapshot.appliedMigrations.allSatisfy({ adjacentPearfyMigrationIDs.contains($0.id) }) else {
            return nil
        }
        let relation = try await database.queryStrings(SQLQuery(
            unsafeSQL: "SELECT COALESCE(to_regclass('public.schema_migrations')::TEXT, '') AS relation"
        ), column: "relation").first ?? ""
        guard !relation.isEmpty else { return nil }
        let dirty = try await database.queryStrings(SQLQuery(
            unsafeSQL: "SELECT COALESCE(bool_or(dirty), false)::TEXT AS dirty FROM public.schema_migrations"
        ), column: "dirty").first ?? "false"
        guard dirty.caseInsensitiveCompare("true") != .orderedSame else {
            throw PopulateSchemaError.schemaDrift([.init(
                path: "migrations.legacyJavaBaseline",
                expected: "clean legacy ledger",
                actual: "dirty"
            )])
        }
        let versionText = try await database.queryStrings(SQLQuery(
            unsafeSQL: "SELECT COALESCE(MAX(version), 0)::TEXT AS version FROM public.schema_migrations"
        ), column: "version").first ?? "0"
        guard let version = Int64(versionText), version > 0 else { return nil }
        guard migrations.count == 1,
              let prefix = migrations[0].id.split(separator: "_", maxSplits: 1).first,
              Int64(prefix) == version else {
            throw PopulateSchemaError.schemaDrift([.init(
                path: "migrations.legacyJavaBaseline",
                expected: "single model baseline at version \(version)",
                actual: migrations.map(\.id).joined(separator: ",")
            )])
        }
        return migrations[0]
    }

    private static func inspection(
        snapshot: PopulateSchemaSnapshot,
        projectRoot: URL,
        environment: PopulateEnvironment
    ) -> [String: Any] {
        let manifestURL = projectRoot.appendingPathComponent(".pearfy/schema.json")
        return [
            "environment": environment.rawValue,
            "database": snapshot.databaseName,
            "serverAddress": snapshot.serverAddress ?? "unix socket or unavailable",
            "serverPort": snapshot.serverPort as Any? ?? NSNull(),
            "schemaFingerprint": (try? snapshot.fingerprint()) ?? "unavailable",
            "tables": snapshot.tables.map { table in
                [
                    "name": table.qualifiedName,
                    "columns": table.columns.map(\.name),
                    "primaryKey": table.primaryKey,
                    "foreignKeyCount": table.foreignKeys.count,
                    "uniqueConstraintCount": table.uniqueConstraints.count,
                    "checkConstraintCount": table.checks.count,
                    "triggerCount": table.triggers.count,
                    "rowLevelSecurity": table.rowLevelSecurity
                ] as [String: Any]
            },
            "appliedMigrationCount": snapshot.appliedMigrations.count,
            "modelSchemaManifest": FileManager.default.fileExists(atPath: manifestURL.path) ? ".pearfy/schema.json" : "not configured"
        ]
    }

    private static func printJSON<Value: Encodable>(_ value: Value) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            print("{}")
            return
        }
        print(String(decoding: data, as: UTF8.self))
    }

    private static func printJSON(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            print("{}")
            return
        }
        print(String(decoding: data, as: UTF8.self))
    }
}

private struct PlanPreview: Encodable {
    let plan: PopulatePlan
    let planPath: String?

    init(plan: PopulatePlan, planPath: String? = nil) {
        self.plan = plan
        self.planPath = planPath
    }
}

private struct VerificationReport: Encodable {
    let state: PopulateRunState
    let verification: PopulateVerification
}

private struct PopulateRunReport: Encodable {
    let state: PopulateRunState
    let plan: PopulatePlan
    let metricComparison: String
}

private struct PopulateRecipe {
    var table: String?
    var environment: PopulateEnvironment?
    var seed: UInt64?
    var rows: Int?
    var targetSize: Int64?
    var sizeMode: PopulateSizeMode?
    var maxRows: Int?
    var maxBatchRows: Int?
    var maxDurationSeconds: Int?
    var minimumFreeDiskBytes: Int64?

    init(contents: String) throws {
        var section = ""
        var targetCount = 0
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).split(separator: "#", maxSplits: 1).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !line.isEmpty else { continue }
            if line == "limits:" { section = "limits"; continue }
            if line == "targets:" { section = "targets"; continue }
            if line == "verification:" { section = "verification"; continue }
            let clean = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
            guard let separator = clean.firstIndex(of: ":") else { continue }
            let key = clean[..<separator].trimmingCharacters(in: .whitespaces)
            let value = clean[clean.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                if ["profileFromLocal", "distributions"].contains(key) { section = key }
                continue
            }
            switch (section, key) {
            case (_, "environment"):
                guard let parsed = PopulateEnvironment(rawValue: value) else { throw PopulateCLIError.invalidRecipe("environment must be local or staging") }
                environment = parsed
            case (_, "seed"):
                guard let parsed = UInt64(value) else { throw PopulateCLIError.invalidRecipe("seed must be an unsigned integer") }
                seed = parsed
            case (_, "mode"):
                guard value == "synthetic" else { throw PopulateCLIError.invalidRecipe("only mode: synthetic is supported") }
            case ("profileFromLocal", "enabled"), ("profileFromLocal", "exportRawRows"):
                guard value == "false" else { throw PopulateCLIError.invalidRecipe("local-data profiling/export recipes are not supported by the synthetic executor") }
            case ("limits", "externalSideEffects"):
                guard value == "deny" else { throw PopulateCLIError.invalidRecipe("externalSideEffects must be deny") }
            case ("limits", "writeExistingRows"):
                guard value == "false" else { throw PopulateCLIError.invalidRecipe("writeExistingRows must be false") }
            case ("limits", "schemaDrift"):
                guard value == "deny" else { throw PopulateCLIError.invalidRecipe("schemaDrift must be deny") }
            case ("limits", "maxWorkers"):
                guard Int(value) == 1 else { throw PopulateCLIError.invalidRecipe("this executor is single-worker; maxWorkers must be 1") }
            case ("targets", "table"):
                targetCount += 1
                guard targetCount == 1 else { throw PopulateCLIError.invalidRecipe("only one target table is supported per plan") }
                table = value
            case ("targets", "rows"):
                guard let parsed = Int(value) else { throw PopulateCLIError.invalidRecipe("target rows must be an integer") }
                rows = parsed
            case ("targets", "targetSize"), ("targets", "target-size"): targetSize = try PearfyPopulateCommand.parseSize(value)
            case ("targets", "sizeMode"), ("targets", "size-mode"):
                guard let parsed = PopulateSizeMode(rawValue: value) else { throw PopulateCLIError.invalidRecipe("sizeMode must be total, table, or heap") }
                sizeMode = parsed
            case ("targets", "targetMeaning"):
                guard value == "total-final" else { throw PopulateCLIError.invalidRecipe("targetMeaning must be total-final") }
            case ("targets", "parents"):
                guard value == "existing" || value == "existing-only" else { throw PopulateCLIError.invalidRecipe("only existing FK parents are supported; parent creation is not implemented") }
            case ("targets", "domainFactory"):
                throw PopulateCLIError.invalidRecipe("domainFactory '\(value)' must be implemented by an application adapter; generic SQL generation will not substitute it")
            case ("limits", "maxRows"):
                guard let parsed = Int(value) else { throw PopulateCLIError.invalidRecipe("maxRows must be an integer") }
                maxRows = parsed
            case ("limits", "maxBatchRows"):
                guard let parsed = Int(value) else { throw PopulateCLIError.invalidRecipe("maxBatchRows must be an integer") }
                maxBatchRows = parsed
            case ("limits", "maxDuration"):
                guard let parsed = Self.parseDuration(value) else { throw PopulateCLIError.invalidRecipe("maxDuration must be a duration such as 900 or 2h") }
                maxDurationSeconds = parsed
            case ("limits", "minFreeDisk"): minimumFreeDiskBytes = try PearfyPopulateCommand.parseSize(value)
            case ("distributions", _):
                throw PopulateCLIError.invalidRecipe("distribution recipes are not implemented; scalar generators use deterministic values")
            case ("verification", "comparePearfyMetric"): break
            case ("verification", _):
                throw PopulateCLIError.invalidRecipe("unsupported verification setting '\(key)'")
            default: break
            }
        }
        guard table != nil else { throw PopulateCLIError.invalidRecipe("recipe must define exactly one targets[].table") }
    }

    private static func parseDuration(_ value: String) -> Int? {
        let number = value.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789"))
        guard let amount = Int(number) else { return nil }
        let unit = String(value.dropFirst(number.count)).lowercased()
        return switch unit {
        case "h", "hr", "hours": amount * 3_600
        case "m", "min", "minutes": amount * 60
        default: amount
        }
    }
}

private struct CommandOptions {
    let values: [String: String]
    let flags: Set<String>
    let positional: [String]

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var positional: [String] = []
        var index = 0
        let knownFlags: Set<String> = ["sample-local", "dry-run", "approval-token-stdin"]
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else { positional.append(argument); index += 1; continue }
            let name = String(argument.dropFirst(2))
            if knownFlags.contains(name) {
                guard flags.insert(name).inserted else { throw PopulateCLIError.duplicateOption(name) }
                index += 1
            } else {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw PopulateCLIError.missingOptionValue(name)
                }
                guard values[name] == nil else { throw PopulateCLIError.duplicateOption(name) }
                values[name] = arguments[index + 1]
                index += 2
            }
        }
        self.values = values
        self.flags = flags
        self.positional = positional
    }

    func required(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else { throw PopulateCLIError.missing(name) }
        return value
    }

    func validate(for command: String) throws {
        let valueOptions: Set<String>
        let allowedFlags: Set<String>
        switch command {
        case "inspect": valueOptions = ["environment"]; allowedFlags = []
        case "profile": valueOptions = ["environment", "table"]; allowedFlags = ["sample-local"]
        case "plan": valueOptions = ["environment", "table", "seed", "rows", "target-size", "size-mode", "max-rows", "max-batch-rows", "max-duration", "min-free-disk", "recipe"]; allowedFlags = ["dry-run"]
        case "preview": valueOptions = ["plan"]; allowedFlags = []
        case "approve": valueOptions = ["plan", "environment"]; allowedFlags = []
        case "run": valueOptions = ["plan", "environment", "approve-plan-hash", "approval-token"]; allowedFlags = ["approval-token-stdin"]
        case "status", "report": valueOptions = ["run"]; allowedFlags = []
        case "verify": valueOptions = ["run", "environment"]; allowedFlags = []
        case "schema": valueOptions = ["environment"]; allowedFlags = []
        default: return
        }
        if let unknown = values.keys.first(where: { !valueOptions.contains($0) }) {
            throw PopulateCLIError.unknownOption(unknown)
        }
        if let unknown = flags.first(where: { !allowedFlags.contains($0) }) {
            throw PopulateCLIError.unknownOption(unknown)
        }
        let validPositionals = command == "schema" ? positional.isEmpty || positional == ["check"] : positional.isEmpty
        guard validPositionals else { throw PopulateCLIError.usage }
    }
}

private enum PopulateCLIError: Error, CustomStringConvertible {
    case usage
    case unknownCommand(String)
    case missing(String)
    case missingOptionValue(String)
    case duplicateOption(String)
    case invalidEnvironment(String)
    case invalidSize(String)
    case invalidRecipe(String)
    case recipeEnvironmentMismatch
    case environmentMismatch
    case profileRequiresLocalSample
    case migrationSourcesMissing
    case modelSchemaMissing
    case invalidModelSchema(String)
    case fileNotFound(String)
    case invalidPlan(String)
    case runNotFound(String)
    case insufficientDisk(available: Int64, required: Int64)
    case approvalInputRequired
    case invalidInteger(String)
    case invalidSizeMode(String)
    case unknownOption(String)

    var description: String {
        switch self {
        case .usage:
            "Usage: pearfy populate <inspect|profile|plan|preview|approve|run|status|verify|report> [options]"
        case .unknownCommand(let value): "unknown populate command '\(value)'"
        case .missing(let value): "required option missing: --\(value)"
        case .missingOptionValue(let value): "missing value for --\(value)"
        case .duplicateOption(let value): "option provided more than once: --\(value)"
        case .invalidEnvironment(let value): "environment must be local or staging; received '\(value)'"
        case .invalidSize(let value): "invalid size '\(value)' (use bytes, KB/MB/GB or KiB/MiB/GiB)"
        case .invalidRecipe(let value): "invalid population recipe: \(value)"
        case .recipeEnvironmentMismatch: "recipe environment differs from the explicit --environment"
        case .environmentMismatch: "plan environment differs from --environment"
        case .profileRequiresLocalSample: "profile requires --environment local --sample-local"
        case .migrationSourcesMissing: "database has applied migrations but this project has no Migrations/ or .pearfy/migrations catalog"
        case .modelSchemaMissing: "model schema manifest is required: add a validated SchemaIR JSON file at .pearfy/schema.json, then run `pearfy populate schema check`"
        case .invalidModelSchema(let path): "invalid SchemaIR model manifest: \(path)"
        case .fileNotFound(let path): "file not found: \(path)"
        case .invalidPlan(let path): "invalid or unsupported population plan: \(path)"
        case .runNotFound(let id): "populate run not found: \(id)"
        case .insufficientDisk(let available, let required):
            "insufficient local disk headroom: \(available) bytes available; \(required) required"
        case .approvalInputRequired: "approval requires a confirmation line on standard input"
        case .invalidInteger(let name): "invalid integer value for \(name)"
        case .invalidSizeMode(let value): "size mode must be total, table, or heap; received '\(value)'"
        case .unknownOption(let value): "unknown populate option: --\(value)"
        }
    }
}

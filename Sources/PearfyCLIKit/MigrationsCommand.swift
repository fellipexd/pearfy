import Foundation
import PearfyData
import PearfyPostgres

/// Pearfy-owned migration catalog import and local PostgreSQL bootstrap.
public enum PearfyMigrationsCommand {
    private struct LegacyMigrationFiles {
        let id: String
        let version: Int
        var up: URL?
        var down: URL?
    }

    public static func run(
        arguments: [String],
        projectRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> Int32 {
        guard let action = arguments.first else { throw PearfyMigrationsCommandError.usage }
        let options = Array(arguments.dropFirst())
        switch action {
        case "import-java":
            try importJava(options: options, projectRoot: projectRoot)
            return 0
        case "generate":
            try generate(options: options, projectRoot: projectRoot)
            return 0
        case "apply":
            try await apply(options: options, projectRoot: projectRoot, environment: environment)
            return 0
        default:
            throw PearfyMigrationsCommandError.usage
        }
    }

    private static func importJava(options: [String], projectRoot: URL) throws {
        var sourcePath: String?
        var outputPath: String?
        var removeSource = false
        var seen: Set<String> = []
        var index = 0
        while index < options.count {
            let option = options[index]
            guard ["--source", "--output", "--remove-source"].contains(option) else {
                throw PearfyMigrationsCommandError.unknownOption(option)
            }
            guard seen.insert(option).inserted else {
                throw PearfyMigrationsCommandError.duplicateOption(option)
            }
            if option == "--remove-source" {
                removeSource = true
                index += 1
                continue
            }
            guard index + 1 < options.count else { throw PearfyMigrationsCommandError.missingValue(option) }
            let value = options[index + 1]
            if option == "--source" { sourcePath = value }
            else { outputPath = value }
            index += 2
        }
        guard let sourcePath else { throw PearfyMigrationsCommandError.missingValue("--source") }

        let source = URL(fileURLWithPath: sourcePath, relativeTo: projectRoot).standardizedFileURL
        let output = URL(
            fileURLWithPath: outputPath ?? "Migrations",
            relativeTo: projectRoot
        ).standardizedFileURL
        try validateDirectory(source, purpose: "Java migration source")
        guard !isWithin(output, of: source), !isWithin(source, of: output) else {
            throw PearfyMigrationsCommandError.overlappingPaths
        }

        let migrations = try readJavaMigrations(from: source)
        let artifacts = migrations.map { item in
            SQLMigrationArtifact(
                id: item.id,
                up: SQLMigrationCommand(sql: item.upSQL),
                down: item.downSQL.map { SQLMigrationCommand(sql: $0) }
            )
        }
        let expectedMigrations = artifacts.map(\.migration)
        let artifactBytes = try Dictionary(uniqueKeysWithValues: artifacts.map { artifact in
            ("\(artifact.id).json", try artifact.canonicalJSON())
        })

        var outputCreated = false
        if FileManager.default.fileExists(atPath: output.path) {
            try validateDirectory(output, purpose: "migration catalog output")
            let entries = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if !entries.isEmpty {
                let existing = try SQLMigrationCatalog(directory: output).migrations
                guard existing.map(\.checksum) == expectedMigrations.map(\.checksum) else {
                    throw PearfyMigrationsCommandError.catalogConflict(output.path)
                }
            }
        } else {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            outputCreated = true
        }

        var filesWritten: [URL] = []
        do {
            let currentEntries = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            if currentEntries.isEmpty {
                for (name, data) in artifactBytes.sorted(by: { $0.key < $1.key }) {
                    let destination = output.appendingPathComponent(name)
                    try data.write(to: destination, options: .atomic)
                    filesWritten.append(destination)
                }
            }
            let catalog = try SQLMigrationCatalog(directory: output)
            guard catalog.migrations.map(\.checksum) == expectedMigrations.map(\.checksum) else {
                throw PearfyMigrationsCommandError.catalogConflict(output.path)
            }
        } catch {
            for file in filesWritten { try? FileManager.default.removeItem(at: file) }
            if outputCreated { try? FileManager.default.removeItem(at: output) }
            throw error
        }

        if removeSource {
            for file in migrations.flatMap({ [$0.up, $0.down].compactMap { $0 } }) {
                try FileManager.default.removeItem(at: file)
            }
            if (try? FileManager.default.contentsOfDirectory(atPath: source.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: source)
            }
        }

        print("Imported \(artifacts.count) Pearfy SQL migration artifacts to \(output.path).")
        if removeSource {
            print("Removed \(migrations.reduce(0) { $0 + 1 + ($1.down == nil ? 0 : 1) }) Java migration SQL source files after catalog validation.")
        }
        print("No database connection or migration execution was performed.")
    }

    private static func readJavaMigrations(from directory: URL) throws -> [(id: String, version: Int, up: URL, down: URL?, upSQL: String, downSQL: String?)] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var pairs: [String: LegacyMigrationFiles] = [:]
        for file in files where file.pathExtension == "sql" {
            let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard metadata.isSymbolicLink != true, metadata.isRegularFile == true else {
                throw PearfyMigrationsCommandError.unsafeSource(file.path)
            }
            let filename = file.lastPathComponent
            let direction: String
            if filename.hasSuffix(".up.sql") { direction = "up" }
            else if filename.hasSuffix(".down.sql") { direction = "down" }
            else { throw PearfyMigrationsCommandError.invalidFilename(filename) }

            let suffix = ".\(direction).sql"
            let id = String(filename.dropLast(suffix.count))
            guard let versionText = id.split(separator: "_", maxSplits: 1).first,
                  !versionText.isEmpty,
                  versionText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let version = Int(versionText),
                  isValidMigrationID(id) else {
                throw PearfyMigrationsCommandError.invalidFilename(filename)
            }
            var pair = pairs[id] ?? LegacyMigrationFiles(id: id, version: version, up: nil, down: nil)
            if direction == "up" {
                guard pair.up == nil else { throw PearfyMigrationsCommandError.duplicateDirection(id, direction) }
                pair.up = file
            } else {
                guard pair.down == nil else { throw PearfyMigrationsCommandError.duplicateDirection(id, direction) }
                pair.down = file
            }
            pairs[id] = pair
        }
        guard !pairs.isEmpty else { throw PearfyMigrationsCommandError.noJavaMigrations(directory.path) }

        let ordered = pairs.values.sorted { $0.version < $1.version }
        guard ordered.first?.version == 1 else { throw PearfyMigrationsCommandError.nonContiguousMigrations }
        for (index, migration) in ordered.enumerated() where migration.version != index + 1 {
            throw PearfyMigrationsCommandError.nonContiguousMigrations
        }
        guard Set(ordered.map(\.version)).count == ordered.count,
              ordered.allSatisfy({ $0.up != nil }) else {
            throw PearfyMigrationsCommandError.invalidPairing
        }

        var totalBytes = 0
        return try ordered.map { migration in
            guard let up = migration.up else { throw PearfyMigrationsCommandError.invalidPairing }
            let upData = try Data(contentsOf: up, options: .mappedIfSafe)
            totalBytes += upData.count
            let downData = try migration.down.map { try Data(contentsOf: $0, options: .mappedIfSafe) }
            totalBytes += downData?.count ?? 0
            guard totalBytes <= 64 * 1_024 * 1_024,
                  let upSQL = String(data: upData, encoding: .utf8),
                  !upSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PearfyMigrationsCommandError.invalidSQL(up.path)
            }
            let downSQL: String?
            if let downData {
                guard let value = String(data: downData, encoding: .utf8),
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PearfyMigrationsCommandError.invalidSQL(migration.down?.path ?? migration.id)
                }
                downSQL = value
            } else {
                downSQL = nil
            }
            return (migration.id, migration.version, up, migration.down, upSQL, downSQL)
        }
    }

    private static func generate(options: [String], projectRoot: URL) throws {
        var modelPath = ".pearfy/schema.json"
        var previousModelPath: String?
        var productName: String?
        var outputPath = "Migrations"
        var migrationID: String?
        var replaceCatalog = false
        var seen: Set<String> = []
        var index = 0
        while index < options.count {
            let option = options[index]
            guard ["--model", "--previous-model", "--product", "--output", "--id", "--replace-catalog"].contains(option) else {
                throw PearfyMigrationsCommandError.unknownOption(option)
            }
            guard seen.insert(option).inserted else {
                throw PearfyMigrationsCommandError.invalidOptions
            }
            if option == "--replace-catalog" {
                replaceCatalog = true
                index += 1
                continue
            }
            guard index + 1 < options.count else { throw PearfyMigrationsCommandError.invalidOptions }
            switch option {
            case "--model": modelPath = options[index + 1]
            case "--previous-model": previousModelPath = options[index + 1]
            case "--product": productName = options[index + 1]
            case "--output": outputPath = options[index + 1]
            case "--id": migrationID = options[index + 1]
            default: throw PearfyMigrationsCommandError.unknownOption(option)
            }
            index += 2
        }

        guard let migrationID, isValidMigrationID(migrationID) else {
            throw PearfyMigrationsCommandError.generatedMigrationIDRequired
        }
        _ = try migrationVersion(migrationID)
        let modelURL = URL(fileURLWithPath: modelPath, relativeTo: projectRoot).standardizedFileURL
        let previousModelURL = previousModelPath.map { URL(fileURLWithPath: $0, relativeTo: projectRoot).standardizedFileURL }
        let outputURL = URL(fileURLWithPath: outputPath, relativeTo: projectRoot).standardizedFileURL
        guard !isWithin(modelURL, of: outputURL),
              previousModelURL != modelURL,
              previousModelURL.map({ !isWithin($0, of: outputURL) }) ?? true else {
            throw PearfyMigrationsCommandError.overlappingPaths
        }
        if let productName {
            try exportSchema(from: productName, to: modelURL, projectRoot: projectRoot)
        }
        let modelData = try Data(contentsOf: modelURL)
        let model: SchemaIR
        do {
            model = try JSONDecoder().decode(SchemaIR.self, from: modelData)
        } catch {
            throw PearfyMigrationsCommandError.invalidModelSchema(modelURL.path)
        }

        let previousModel: SchemaIR?
        if let previousModelURL {
            do {
                previousModel = try JSONDecoder().decode(SchemaIR.self, from: Data(contentsOf: previousModelURL))
            } catch {
                throw PearfyMigrationsCommandError.invalidModelSchema(previousModelURL.path)
            }
        } else {
            previousModel = nil
        }
        let plan = try PostgresSchemaCompiler().plan(from: previousModel, to: model)
        guard !plan.upStatements.isEmpty else {
            throw PearfyMigrationsCommandError.emptyGeneratedSchema(modelURL.path)
        }
        let sql = plan.upStatements.joined(separator: ";\n") + ";\n"
        let artifact = SQLMigrationArtifact(
            id: migrationID,
            up: SQLMigrationCommand(sql: sql)
        )
        let outputExists = FileManager.default.fileExists(atPath: outputURL.path)
        if outputExists {
            try validateDirectory(outputURL, purpose: "migration catalog output")
            let existing = try FileManager.default.contentsOfDirectory(at: outputURL, includingPropertiesForKeys: nil)
            if !existing.isEmpty {
                guard replaceCatalog,
                      existing.allSatisfy({ $0.pathExtension == "json" }),
                      (try? SQLMigrationCatalog(directory: outputURL)) != nil else {
                    throw PearfyMigrationsCommandError.catalogConflict(outputURL.path)
                }
            }
        }

        let fileManager = FileManager.default
        let parentURL = outputURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let stagingURL = parentURL.appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).staging", isDirectory: true)
        let backupURL = parentURL.appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).backup", isDirectory: true)
        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            let stagedArtifact = stagingURL.appendingPathComponent("\(migrationID).json")
            try artifact.canonicalJSON().write(to: stagedArtifact, options: .atomic)
            let stagedCatalog = try SQLMigrationCatalog(directory: stagingURL)
            guard stagedCatalog.migrations.count == 1, stagedCatalog.migrations[0].id == migrationID else {
                throw PearfyMigrationsCommandError.catalogConflict(stagingURL.path)
            }

            if outputExists {
                try fileManager.moveItem(at: outputURL, to: backupURL)
            }
            do {
                try fileManager.moveItem(at: stagingURL, to: outputURL)
            } catch {
                if outputExists { try? fileManager.moveItem(at: backupURL, to: outputURL) }
                throw error
            }
            if outputExists { try fileManager.removeItem(at: backupURL) }
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
        let artifactURL = outputURL.appendingPathComponent("\(migrationID).json")
        print("Generated Pearfy migration \(migrationID) from \(modelURL.path) at \(artifactURL.path).")
        print("Model fingerprint: \(try model.fingerprint())")
        print("No database connection or migration execution was performed.")
    }

    private static func exportSchema(from productName: String, to modelURL: URL, projectRoot: URL) throws {
        guard !productName.isEmpty, !productName.contains("/") else {
            throw PearfyMigrationsCommandError.invalidSchemaProduct(productName)
        }
        try FileManager.default.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift", "run", "--package-path", projectRoot.path,
            productName, "--pearfy-export-schema", modelURL.path
        ]
        process.currentDirectoryURL = projectRoot
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: modelURL.path) else {
            throw PearfyMigrationsCommandError.schemaExportFailed(productName)
        }
    }

    private static func apply(options: [String], projectRoot: URL, environment: [String: String]) async throws {
        var directoryPath = "Migrations"
        var targetEnvironment: String?
        var seen: Set<String> = []
        var index = 0
        while index < options.count {
            let option = options[index]
            guard ["--directory", "--environment"].contains(option) else {
                throw PearfyMigrationsCommandError.unknownOption(option)
            }
            guard seen.insert(option).inserted, index + 1 < options.count else {
                throw PearfyMigrationsCommandError.invalidOptions
            }
            if option == "--directory" { directoryPath = options[index + 1] }
            else { targetEnvironment = options[index + 1] }
            index += 2
        }
        guard targetEnvironment == "local" else { throw PearfyMigrationsCommandError.localEnvironmentRequired }

        let catalogURL = URL(fileURLWithPath: directoryPath, relativeTo: projectRoot).standardizedFileURL
        let catalog = try SQLMigrationCatalog(directory: catalogURL)
        let settings = try connectionSettings(environment: environment)
        let isLoopback = isLoopbackHost(settings.host)
        guard isLoopback || environment["PEARFY_MIGRATIONS_ALLOW_REMOTE_LOCAL"] == "1" else {
            throw PearfyMigrationsCommandError.remoteLocalRequiresOptIn
        }
        let lowerDatabase = (settings.database ?? "").lowercased()
        guard !["production", "prod", "live"].contains(where: lowerDatabase.contains) else {
            throw PearfyMigrationsCommandError.productionDatabaseRefused
        }

        let database = PearfyPostgresDatabase(settings: settings)
        try await database.start()
        do {
            let legacyVersion = try await legacyJavaVersion(in: database)
            if let legacyVersion, legacyVersion > 0 {
                let latest = try catalog.migrations.map { try migrationVersion($0.id) }.max() ?? 0
                guard legacyVersion <= latest else {
                    throw PearfyMigrationsCommandError.legacyVersionAhead(legacyVersion, latest)
                }
                guard legacyVersion == latest else {
                    throw PearfyMigrationsCommandError.legacyVersionBehind(legacyVersion, latest)
                }
                print("Legacy Java migration ledger detected at version \(legacyVersion); preserving this database without Pearfy bootstrap writes.")
                try await database.stop()
                return
            }

            let hasApplicationTables = try await hasTablesOutsideMigrationJournal(in: database)
            let hasPearfyJournal = try await hasPearfyMigrationJournal(in: database)
            guard !hasApplicationTables || hasPearfyJournal else {
                throw PearfyMigrationsCommandError.untrackedExistingSchema
            }
            try await SQLMigrationRunner().apply(catalog.migrations, to: database)
            print("Applied or verified \(catalog.migrations.count) Pearfy migration artifacts from \(catalogURL.path).")
            try await database.stop()
        } catch {
            try? await database.stop()
            throw error
        }
    }

    private static func connectionSettings(environment: [String: String]) throws -> PearfyPostgresConnectionSettings {
        guard let username = environment["PEARFY_DATABASE_USERNAME"] ?? environment["PEARFY_POPULATE_PGUSER"] ?? environment["PGUSER"],
              let database = environment["PEARFY_DATABASE_NAME"] ?? environment["PEARFY_POPULATE_DATABASE"] ?? environment["PGDATABASE"] else {
            throw PearfyMigrationsCommandError.databaseConfigurationMissing
        }
        let host = environment["PEARFY_DATABASE_HOST"] ?? environment["PEARFY_POPULATE_PGHOST"] ?? environment["PGHOST"] ?? "127.0.0.1"
        let portText = environment["PEARFY_DATABASE_PORT"] ?? environment["PEARFY_POPULATE_PGPORT"] ?? environment["PGPORT"] ?? "5432"
        guard let port = Int(portText) else { throw PearfyMigrationsCommandError.invalidDatabaseConfiguration }
        let tlsText = environment["PEARFY_DATABASE_TLS"]?.lowercased() ?? "false"
        let tls: PearfyPostgresTLSMode
        switch tlsText {
        case "true", "required": tls = .required
        case "prefer": tls = .prefer
        case "false", "disabled": tls = .disabled
        default: throw PearfyMigrationsCommandError.invalidDatabaseConfiguration
        }
        let timeoutText = environment["PEARFY_DATABASE_CONNECT_TIMEOUT_SECONDS"] ?? "5"
        guard let timeoutSeconds = Int(timeoutText), timeoutSeconds > 0 else {
            throw PearfyMigrationsCommandError.invalidDatabaseConfiguration
        }
        return try PearfyPostgresConnectionSettings(
            host: host,
            port: port,
            username: username,
            password: environment["PEARFY_DATABASE_PASSWORD"] ?? environment["PEARFY_POPULATE_PGPASSWORD"] ?? environment["PGPASSWORD"],
            database: database,
            tls: tls,
            maximumConnections: 1,
            connectTimeout: .seconds(Int64(timeoutSeconds))
        )
    }

    private static func legacyJavaVersion(in database: any SQLDatabase) async throws -> Int64? {
        let relation = try await database.queryStrings(SQLQuery(
            unsafeSQL: "SELECT COALESCE(to_regclass('public.schema_migrations')::TEXT, '') AS relation"
        ), column: "relation").first ?? ""
        guard !relation.isEmpty else { return nil }
        let dirty = try await database.queryStrings(SQLQuery(
            unsafeSQL: "SELECT COALESCE(bool_or(dirty), false)::TEXT AS dirty FROM public.schema_migrations"
        ), column: "dirty").first ?? "false"
        guard dirty.caseInsensitiveCompare("true") != .orderedSame else {
            throw PearfyMigrationsCommandError.dirtyLegacyMigrationHistory
        }
        let version = try await database.queryStrings(SQLQuery(
            unsafeSQL: "SELECT COALESCE(MAX(version), 0)::TEXT AS version FROM public.schema_migrations"
        ), column: "version").first ?? "0"
        guard let parsed = Int64(version) else { throw PearfyMigrationsCommandError.invalidLegacyMigrationHistory }
        return parsed
    }

    private static func hasTablesOutsideMigrationJournal(in database: any SQLDatabase) async throws -> Bool {
        let result = try await database.queryStrings(SQLQuery(unsafeSQL: """
        SELECT EXISTS (
            SELECT 1 FROM pg_tables
            WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
              AND NOT (schemaname = 'public' AND tablename = 'pearfy_schema_migrations')
        )::TEXT AS present
        """), column: "present").first
        return result?.caseInsensitiveCompare("true") == .orderedSame
    }

    private static func hasPearfyMigrationJournal(in database: any SQLDatabase) async throws -> Bool {
        let result = try await database.queryStrings(SQLQuery(
            unsafeSQL: "SELECT COALESCE(to_regclass('public.pearfy_schema_migrations')::TEXT, '') AS relation"
        ), column: "relation").first ?? ""
        return !result.isEmpty
    }

    private static func migrationVersion(_ id: String) throws -> Int {
        guard let prefix = id.split(separator: "_", maxSplits: 1).first,
              !prefix.isEmpty,
              prefix.utf8.allSatisfy({ (48...57).contains($0) }),
              let version = Int(prefix) else {
            throw PearfyMigrationsCommandError.invalidMigrationID(id)
        }
        return version
    }

    private static func isValidMigrationID(_ id: String) -> Bool {
        let bytes = id.utf8
        guard let first = bytes.first, (48...57).contains(first) else { return false }
        return bytes.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func validateDirectory(_ directory: URL, purpose: String) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw PearfyMigrationsCommandError.invalidDirectory(purpose, directory.path)
        }
    }

    private static func isWithin(_ candidate: URL, of parent: URL) -> Bool {
        candidate.path == parent.path || candidate.path.hasPrefix(parent.path + "/")
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return normalized == "localhost" || normalized == "::1"
            || normalized.hasPrefix("127.")
    }
}

private enum PearfyMigrationsCommandError: Error, Sendable, CustomStringConvertible {
    case usage
    case unknownOption(String)
    case duplicateOption(String)
    case missingValue(String)
    case invalidOptions
    case overlappingPaths
    case invalidDirectory(String, String)
    case unsafeSource(String)
    case noJavaMigrations(String)
    case invalidFilename(String)
    case duplicateDirection(String, String)
    case nonContiguousMigrations
    case invalidPairing
    case invalidSQL(String)
    case catalogConflict(String)
    case databaseConfigurationMissing
    case invalidDatabaseConfiguration
    case localEnvironmentRequired
    case remoteLocalRequiresOptIn
    case productionDatabaseRefused
    case legacyVersionAhead(Int64, Int)
    case legacyVersionBehind(Int64, Int)
    case dirtyLegacyMigrationHistory
    case invalidLegacyMigrationHistory
    case untrackedExistingSchema
    case invalidMigrationID(String)
    case generatedMigrationIDRequired
    case invalidModelSchema(String)
    case emptyGeneratedSchema(String)
    case invalidSchemaProduct(String)
    case schemaExportFailed(String)

    var description: String {
        switch self {
        case .usage:
            "Usage: pearfy migrations generate --id <version_name> [--model <SchemaIR.json>] [--previous-model <SchemaIR.json>] [--product <SwiftPM-product>] [--output <directory>] [--replace-catalog] | pearfy migrations import-java --source <directory> [--output <directory>] [--remove-source] | pearfy migrations apply --environment local [--directory <directory>]"
        case .unknownOption(let option): "unknown option: \(option)"
        case .duplicateOption(let option): "option provided more than once: \(option)"
        case .missingValue(let option): "missing value for \(option)"
        case .invalidOptions: "invalid or duplicate migration command options"
        case .overlappingPaths: "migration source and output directories must not overlap"
        case .invalidDirectory(let purpose, let path): "invalid \(purpose) directory: \(path)"
        case .unsafeSource(let path): "refusing a symbolic link or non-regular migration source: \(path)"
        case .noJavaMigrations(let path): "no versioned Java SQL migrations found in \(path)"
        case .invalidFilename(let filename): "invalid migration filename: \(filename)"
        case .duplicateDirection(let id, let direction): "duplicate \(direction) migration source for \(id)"
        case .nonContiguousMigrations: "Java migration versions must be unique, contiguous, and start at 1"
        case .invalidPairing: "every Java migration requires exactly one .up.sql file and at most one .down.sql file"
        case .invalidSQL(let path): "migration SQL is empty or not UTF-8: \(path)"
        case .catalogConflict(let path): "existing Pearfy migration catalog differs from Java sources: \(path)"
        case .databaseConfigurationMissing: "set PEARFY_DATABASE_HOST/USERNAME/NAME (or PostgreSQL environment equivalents)"
        case .invalidDatabaseConfiguration: "invalid PostgreSQL migration connection configuration"
        case .localEnvironmentRequired: "`pearfy migrations apply` currently requires --environment local"
        case .remoteLocalRequiresOptIn: "remote local PostgreSQL requires PEARFY_MIGRATIONS_ALLOW_REMOTE_LOCAL=1"
        case .productionDatabaseRefused: "production-like databases are refused by local migration bootstrap"
        case .legacyVersionAhead(let current, let latest): "legacy schema version \(current) is ahead of Pearfy catalog version \(latest)"
        case .legacyVersionBehind(let current, let latest): "legacy schema version \(current) differs from Pearfy catalog version \(latest); preserving this database requires an explicit migration baseline decision"
        case .dirtyLegacyMigrationHistory: "legacy schema_migrations is dirty; refusing Pearfy migration bootstrap"
        case .invalidLegacyMigrationHistory: "legacy schema_migrations version is invalid"
        case .untrackedExistingSchema: "database has application tables but no migration journal; refusing a fresh Pearfy bootstrap"
        case .invalidMigrationID(let id): "migration ID is not a numeric legacy version: \(id)"
        case .generatedMigrationIDRequired: "migration generation requires a numeric --id such as 000051_embersquare_baseline"
        case .invalidModelSchema(let path): "invalid Pearfy SchemaIR model: \(path)"
        case .emptyGeneratedSchema(let path): "Pearfy SchemaIR model generates no DDL: \(path)"
        case .invalidSchemaProduct(let product): "invalid SwiftPM product for schema export: \(product)"
        case .schemaExportFailed(let product): "schema export failed for product '\(product)'; implement --pearfy-export-schema <path> using PearfyGeneratedSchemaRegistry.entities"
        }
    }
}

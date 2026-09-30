import Crypto
import Foundation

public enum PopulateEnvironment: String, Codable, Sendable {
    case local
    case staging
}

public enum PopulateSafetyError: Error, Sendable, Equatable, CustomStringConvertible {
    case productionLikeTarget(String)
    case localTargetIsRemote(String)
    case stagingOptInRequired

    public var description: String {
        switch self {
        case .productionLikeTarget(let target): "PEARFY_POPULATE_019: production-like target is not permitted: \(target)"
        case .localTargetIsRemote(let target): "PEARFY_POPULATE_020: local mode requires loopback PostgreSQL; found \(target) (set PEARFY_POPULATE_ALLOW_REMOTE_LOCAL=1 only for an isolated local network)"
        case .stagingOptInRequired: "PEARFY_POPULATE_021: staging writes require PEARFY_POPULATE_ALLOW_STAGING=1"
        }
    }
}

public enum PopulateSafetyGuard {
    public static func validate(
        environment: PopulateEnvironment,
        host: String,
        database: String,
        allowRemoteLocal: Bool = false,
        allowStaging: Bool = false
    ) throws {
        let values = [host, database].map { $0.lowercased() }
        let productionMarkers = ["prod", "production", "live", "primary"]
        if let target = values.first(where: { value in productionMarkers.contains(where: value.contains) }) {
            throw PopulateSafetyError.productionLikeTarget(target)
        }
        switch environment {
        case .local:
            let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let loopback = ["localhost", "127.0.0.1", "::1", "."].contains(normalizedHost)
                || normalizedHost.hasPrefix("/var/run/postgresql")
                || normalizedHost.hasPrefix("/tmp/")
            guard loopback || allowRemoteLocal else { throw PopulateSafetyError.localTargetIsRemote(host) }
        case .staging:
            guard allowStaging else { throw PopulateSafetyError.stagingOptInRequired }
        }
    }
}

public enum PopulateSizeMode: String, Codable, Sendable {
    case total
    case table
    case heap
}

public struct PopulateExecutionLimits: Codable, Equatable, Sendable {
    public let maxRows: Int
    public let maxDurationSeconds: Int
    public let maxBatchRows: Int
    public let maxRetries: Int
    public let minimumFreeDiskBytes: Int64

    public init(
        maxRows: Int = 100_000,
        maxDurationSeconds: Int = 900,
        maxBatchRows: Int = 1_000,
        maxRetries: Int = 2,
        minimumFreeDiskBytes: Int64 = 1_073_741_824
    ) throws {
        guard maxRows > 0, maxDurationSeconds > 0, (1...10_000).contains(maxBatchRows), (0...5).contains(maxRetries), minimumFreeDiskBytes >= 0 else {
            throw PopulatePlanError.invalidLimits
        }
        self.maxRows = maxRows
        self.maxDurationSeconds = maxDurationSeconds
        self.maxBatchRows = maxBatchRows
        self.maxRetries = maxRetries
        self.minimumFreeDiskBytes = minimumFreeDiskBytes
    }
}

public struct PopulatePlan: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let id: String
    public let planHash: String
    public let environment: PopulateEnvironment
    public let databaseName: String
    public let table: String
    public let schemaFingerprint: String
    public let seed: UInt64
    public let rowCount: Int
    public let initialRowCount: Int64
    public let initialSizeBytes: Int64
    public let targetSizeBytes: Int64?
    public let sizeMode: PopulateSizeMode?
    public let estimatedBytesPerRow: Int64
    public let integerUniqueBases: [String: Int64]
    public let limits: PopulateExecutionLimits
    public let dependencies: [String]

    private struct HashPayload: Codable {
        let formatVersion: Int
        let environment: PopulateEnvironment
        let databaseName: String
        let table: String
        let schemaFingerprint: String
        let seed: UInt64
        let rowCount: Int
        let initialRowCount: Int64
        let initialSizeBytes: Int64
        let targetSizeBytes: Int64?
        let sizeMode: PopulateSizeMode?
        let estimatedBytesPerRow: Int64
        let integerUniqueBases: [String: Int64]
        let limits: PopulateExecutionLimits
        let dependencies: [String]
    }

    public init(
        environment: PopulateEnvironment,
        databaseName: String,
        table: String,
        schemaFingerprint: String,
        seed: UInt64,
        rowCount: Int,
        initialRowCount: Int64,
        initialSizeBytes: Int64,
        targetSizeBytes: Int64? = nil,
        sizeMode: PopulateSizeMode? = nil,
        estimatedBytesPerRow: Int64,
        integerUniqueBases: [String: Int64] = [:],
        limits: PopulateExecutionLimits,
        dependencies: [String] = []
    ) throws {
        guard rowCount >= 0,
              rowCount <= limits.maxRows,
              initialRowCount >= 0,
              initialSizeBytes >= 0,
              targetSizeBytes.map({ $0 > 0 }) ?? true,
              estimatedBytesPerRow > 0,
              !databaseName.isEmpty,
              !schemaFingerprint.isEmpty else {
            throw PopulatePlanError.invalidPlan
        }
        self.formatVersion = 1
        self.environment = environment
        self.databaseName = databaseName
        self.table = table
        self.schemaFingerprint = schemaFingerprint
        self.seed = seed
        self.rowCount = rowCount
        self.initialRowCount = initialRowCount
        self.initialSizeBytes = initialSizeBytes
        self.targetSizeBytes = targetSizeBytes
        self.sizeMode = sizeMode
        self.estimatedBytesPerRow = estimatedBytesPerRow
        self.integerUniqueBases = integerUniqueBases
        self.limits = limits
        self.dependencies = dependencies.sorted()

        let payload = HashPayload(
            formatVersion: 1,
            environment: environment,
            databaseName: databaseName,
            table: table,
            schemaFingerprint: schemaFingerprint,
            seed: seed,
            rowCount: rowCount,
            initialRowCount: initialRowCount,
            initialSizeBytes: initialSizeBytes,
            targetSizeBytes: targetSizeBytes,
            sizeMode: sizeMode,
            estimatedBytesPerRow: estimatedBytesPerRow,
            integerUniqueBases: integerUniqueBases,
            limits: limits,
            dependencies: dependencies.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(payload)).map { String(format: "%02x", $0) }.joined()
        planHash = digest
        id = "populate-" + digest.prefix(20)
    }
}

public struct PopulatePlanRequest: Sendable {
    public let table: String
    public let environment: PopulateEnvironment
    public let seed: UInt64
    public let requestedRows: Int?
    public let targetSizeBytes: Int64?
    public let sizeMode: PopulateSizeMode?
    public let limits: PopulateExecutionLimits
    public let integerUniqueBases: [String: Int64]

    public init(
        table: String,
        environment: PopulateEnvironment,
        seed: UInt64 = 1,
        requestedRows: Int? = nil,
        targetSizeBytes: Int64? = nil,
        sizeMode: PopulateSizeMode? = nil,
        limits: PopulateExecutionLimits = try! PopulateExecutionLimits(),
        integerUniqueBases: [String: Int64] = [:]
    ) throws {
        guard (requestedRows == nil) != (targetSizeBytes == nil),
              requestedRows.map({ $0 >= 0 }) ?? true,
              targetSizeBytes.map({ $0 > 0 }) ?? true,
              (targetSizeBytes == nil) == (sizeMode == nil) else {
            throw PopulatePlanError.invalidRequest
        }
        self.table = table
        self.environment = environment
        self.seed = seed
        self.requestedRows = requestedRows
        self.targetSizeBytes = targetSizeBytes
        self.sizeMode = sizeMode
        self.limits = limits
        self.integerUniqueBases = integerUniqueBases
    }
}

public enum PopulatePlanner {
    public static func makePlan(
        request: PopulatePlanRequest,
        snapshot: PopulateSchemaSnapshot,
        currentRowCount: Int64,
        currentSizeBytes: Int64,
        estimatedBytesPerRow: Int64? = nil
    ) throws -> PopulatePlan {
        let target = try snapshot.table(named: request.table)
        let fingerprint = try snapshot.fingerprint()
        let estimated = max(1, estimatedBytesPerRow ?? estimateRowBytes(for: target))
        let rows: Int
        if let requestedRows = request.requestedRows {
            rows = requestedRows
        } else if let targetBytes = request.targetSizeBytes {
            let additionalBytes = max(0, targetBytes - currentSizeBytes)
            let estimatedRows = additionalBytes / estimated + (additionalBytes % estimated == 0 ? 0 : 1)
            let projected = additionalBytes == 0 ? 0 : Int(min(Int64(request.limits.maxRows), estimatedRows))
            rows = projected
        } else {
            throw PopulatePlanError.invalidRequest
        }
        guard rows <= request.limits.maxRows else {
            throw PopulatePlanError.rowLimitExceeded(requested: rows, maximum: request.limits.maxRows)
        }
        if request.targetSizeBytes != nil && request.sizeMode == nil {
            throw PopulatePlanError.invalidRequest
        }
        let dependencyOrder = try PopulateDependencyPlanner.order(for: [target], knownTables: snapshot.tables)
            .filter { $0 != target.qualifiedName }

        return try PopulatePlan(
            environment: request.environment,
            databaseName: snapshot.databaseName,
            table: target.qualifiedName,
            schemaFingerprint: fingerprint,
            seed: request.seed,
            rowCount: rows,
            initialRowCount: currentRowCount,
            initialSizeBytes: currentSizeBytes,
            targetSizeBytes: request.targetSizeBytes,
            sizeMode: request.sizeMode,
            estimatedBytesPerRow: estimated,
            integerUniqueBases: request.integerUniqueBases,
            limits: request.limits,
            dependencies: dependencyOrder
        )
    }

    public static func estimateRowBytes(for table: PopulateTable) -> Int64 {
        let payload = table.columns.reduce(Int64(0)) { total, column in
            let type = column.sqlType.lowercased()
            let estimate: Int64
            if type.contains("uuid") { estimate = 16 }
            else if type.contains("bool") { estimate = 1 }
            else if type.contains("bigint") || type.contains("int8") || type.contains("timestamp") { estimate = 8 }
            else if type.contains("int") { estimate = 4 }
            else if type.contains("numeric") || type.contains("decimal") { estimate = 16 }
            else if type.contains("bytea") { estimate = 64 }
            else if type.contains("char") && column.maximumLength != nil { estimate = Int64(min(column.maximumLength!, 256)) }
            else { estimate = 64 }
            return total + estimate + 8
        }
        return max(32, payload + 24)
    }
}

public enum PopulateDependencyPlanner {
    public static func order(for targets: [PopulateTable], knownTables: [PopulateTable]) throws -> [String] {
        let byQualifiedName = Dictionary(uniqueKeysWithValues: knownTables.map { ($0.qualifiedName, $0) })
        let byName = Dictionary(grouping: knownTables, by: \.name)
        var output: [String] = []
        var visited: Set<String> = []
        var active: [String] = []

        func resolve(_ schema: String, _ table: String) throws -> String {
            let qualified = "\(schema).\(table)"
            if byQualifiedName[qualified] != nil { return qualified }
            guard let matches = byName[table], matches.count == 1, let match = matches.first else {
                throw PopulateSchemaError.tableNotFound(qualified)
            }
            return match.qualifiedName
        }

        func visit(_ table: PopulateTable) throws {
            let name = table.qualifiedName
            if visited.contains(name) { return }
            if let cycleStart = active.firstIndex(of: name) {
                throw PopulatePlanError.foreignKeyCycle(Array(active[cycleStart...]) + [name])
            }
            active.append(name)
            for foreignKey in table.foreignKeys.sorted(by: { $0.name < $1.name }) {
                let parentName = try resolve(foreignKey.referencedSchema, foreignKey.referencedTable)
                guard let parent = byQualifiedName[parentName] else { throw PopulateSchemaError.tableNotFound(parentName) }
                try visit(parent)
            }
            active.removeLast()
            visited.insert(name)
            output.append(name)
        }

        for target in targets.sorted(by: { $0.qualifiedName < $1.qualifiedName }) { try visit(target) }
        return output
    }
}

public enum PopulatePlanError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidRequest
    case invalidPlan
    case invalidLimits
    case rowLimitExceeded(requested: Int, maximum: Int)
    case foreignKeyCycle([String])

    public var description: String {
        switch self {
        case .invalidRequest: "PEARFY_POPULATE_004: specify exactly one of row count or target size, and a size mode for size targets"
        case .invalidPlan: "PEARFY_POPULATE_005: plan contains invalid values"
        case .invalidLimits: "PEARFY_POPULATE_006: execution limits are invalid"
        case .rowLimitExceeded(let requested, let maximum): "PEARFY_POPULATE_007: requested rows \(requested) exceed the maximum of \(maximum)"
        case .foreignKeyCycle(let path): "PEARFY_POPULATE_008: foreign-key cycle cannot be populated safely: \(path.joined(separator: " -> "))"
        }
    }
}

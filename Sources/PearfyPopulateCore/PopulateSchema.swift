import Crypto
import Foundation
import PearfyData

public struct PopulateColumn: Codable, Equatable, Sendable {
    public let name: String
    public let sqlType: String
    public let nullable: Bool
    public let hasDefault: Bool
    public let identity: Bool
    public let generated: Bool
    public let maximumLength: Int?
    public let enumValues: [String]

    public init(
        name: String,
        sqlType: String,
        nullable: Bool,
        hasDefault: Bool = false,
        identity: Bool = false,
        generated: Bool = false,
        maximumLength: Int? = nil,
        enumValues: [String] = []
    ) {
        self.name = name
        self.sqlType = sqlType
        self.nullable = nullable
        self.hasDefault = hasDefault
        self.identity = identity
        self.generated = generated
        self.maximumLength = maximumLength
        self.enumValues = enumValues
    }
}

public struct PopulateUniqueConstraint: Codable, Equatable, Sendable {
    public let name: String
    public let columns: [String]
    public let definition: String
    public let isPartial: Bool
    public let hasExpressions: Bool

    public init(
        name: String,
        columns: [String],
        definition: String = "",
        isPartial: Bool = false,
        hasExpressions: Bool = false
    ) {
        self.name = name
        self.columns = columns
        self.definition = definition
        self.isPartial = isPartial
        self.hasExpressions = hasExpressions
    }
}

public struct PopulateForeignKey: Codable, Equatable, Sendable {
    public let name: String
    public let columns: [String]
    public let referencedSchema: String
    public let referencedTable: String
    public let referencedColumns: [String]
    public let isDeferrable: Bool

    public init(
        name: String,
        columns: [String],
        referencedSchema: String,
        referencedTable: String,
        referencedColumns: [String],
        isDeferrable: Bool = false
    ) {
        self.name = name
        self.columns = columns
        self.referencedSchema = referencedSchema
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.isDeferrable = isDeferrable
    }
}

public struct PopulateCheckConstraint: Codable, Equatable, Sendable {
    public let name: String
    public let expression: String

    public init(name: String, expression: String) {
        self.name = name
        self.expression = expression
    }
}

public struct PopulateTable: Codable, Equatable, Sendable {
    public let schema: String
    public let name: String
    public let columns: [PopulateColumn]
    public let primaryKey: [String]
    public let uniqueConstraints: [PopulateUniqueConstraint]
    public let foreignKeys: [PopulateForeignKey]
    public let checks: [PopulateCheckConstraint]
    public let triggers: [String]
    public let rowLevelSecurity: Bool
    public let isPartitioned: Bool

    public init(
        schema: String,
        name: String,
        columns: [PopulateColumn],
        primaryKey: [String],
        uniqueConstraints: [PopulateUniqueConstraint] = [],
        foreignKeys: [PopulateForeignKey] = [],
        checks: [PopulateCheckConstraint] = [],
        triggers: [String] = [],
        rowLevelSecurity: Bool = false,
        isPartitioned: Bool = false
    ) {
        self.schema = schema
        self.name = name
        self.columns = columns
        self.primaryKey = primaryKey
        self.uniqueConstraints = uniqueConstraints
        self.foreignKeys = foreignKeys
        self.checks = checks
        self.triggers = triggers
        self.rowLevelSecurity = rowLevelSecurity
        self.isPartitioned = isPartitioned
    }

    public var qualifiedName: String { "\(schema).\(name)" }

    public func column(named name: String) -> PopulateColumn? {
        columns.first { $0.name == name }
    }
}

public struct PopulateAppliedMigration: Codable, Equatable, Sendable {
    public let id: String
    public let checksum: String?

    public init(id: String, checksum: String?) {
        self.id = id
        self.checksum = checksum
    }
}

public struct PopulateSchemaSnapshot: Codable, Equatable, Sendable {
    public let databaseName: String
    public let serverAddress: String?
    public let serverPort: Int?
    public let tables: [PopulateTable]
    public let appliedMigrations: [PopulateAppliedMigration]

    public init(
        databaseName: String,
        serverAddress: String? = nil,
        serverPort: Int? = nil,
        tables: [PopulateTable],
        appliedMigrations: [PopulateAppliedMigration] = []
    ) {
        self.databaseName = databaseName
        self.serverAddress = serverAddress
        self.serverPort = serverPort
        self.tables = tables.sorted { $0.qualifiedName < $1.qualifiedName }
        self.appliedMigrations = appliedMigrations.sorted { $0.id < $1.id }
    }

    public func table(named name: String) throws -> PopulateTable {
        let matches = tables.filter { $0.qualifiedName == name || $0.name == name }
        guard matches.count == 1, let table = matches.first else {
            throw PopulateSchemaError.tableNotFound(name)
        }
        return table
    }

    public func fingerprint() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct PopulateSchemaDifference: Codable, Equatable, Sendable {
    public let path: String
    public let expected: String
    public let actual: String

    public init(path: String, expected: String, actual: String) {
        self.path = path
        self.expected = expected
        self.actual = actual
    }
}

public struct PopulateSchemaReconciliation: Codable, Equatable, Sendable {
    public let desiredFingerprint: String
    public let actualFingerprint: String
    public let differences: [PopulateSchemaDifference]

    public var isCompatible: Bool { differences.isEmpty }
}

public enum PopulateSchemaReconciler {
    /// Compares the compile-time Pearfy schema and declared migrations with the
    /// deployed database snapshot. It does not run or plan DDL.
    public static func reconcile(
        desired: SchemaIR,
        migrations: [SQLMigration],
        actual: PopulateSchemaSnapshot
    ) throws -> PopulateSchemaReconciliation {
        let actualTables = Dictionary(grouping: actual.tables, by: \.name)
        var differences: [PopulateSchemaDifference] = []

        for entity in desired.entities {
            guard let candidates = actualTables[entity.table], candidates.count == 1,
                  let liveTable = candidates.first else {
                differences.append(.init(path: "tables.\(entity.table)", expected: "present once", actual: "missing or ambiguous"))
                continue
            }
            let liveColumns = Dictionary(uniqueKeysWithValues: liveTable.columns.map { ($0.name, $0) })
            for column in entity.columns {
                guard let live = liveColumns[column.name] else {
                    differences.append(.init(path: "\(entity.table).\(column.name)", expected: "present", actual: "missing"))
                    continue
                }
                let expectedType = Self.normalizedType(column.type)
                let actualType = Self.normalizedType(live.sqlType)
                if expectedType != actualType {
                    differences.append(.init(path: "\(entity.table).\(column.name).type", expected: expectedType, actual: actualType))
                }
                if column.nullable != live.nullable {
                    differences.append(.init(path: "\(entity.table).\(column.name).nullable", expected: String(column.nullable), actual: String(live.nullable)))
                }
            }
            let desiredPrimaryKey = entity.primaryKey.isEmpty
                ? entity.columns.filter(\.primaryKey).map(\.name)
                : entity.primaryKey
            if desiredPrimaryKey != liveTable.primaryKey {
                differences.append(.init(
                    path: "\(entity.table).primaryKey",
                    expected: desiredPrimaryKey.joined(separator: ","),
                    actual: liveTable.primaryKey.joined(separator: ",")
                ))
            }
            var desiredUniqueKeys = Set(entity.columns.filter(\.unique).map { $0.name })
            for unique in entity.uniqueConstraints {
                desiredUniqueKeys.insert(unique.columns.joined(separator: ","))
            }
            for index in entity.indexes where index.unique && !index.columns.isEmpty {
                desiredUniqueKeys.insert(index.columns.joined(separator: ","))
            }
            let actualUniqueKeys = Set(liveTable.uniqueConstraints
                .filter { !$0.isPartial && !$0.hasExpressions && $0.columns != liveTable.primaryKey }
                .map { $0.columns.joined(separator: ",") })
            if desiredUniqueKeys != actualUniqueKeys {
                differences.append(.init(
                    path: "\(entity.table).uniqueConstraints",
                    expected: desiredUniqueKeys.sorted().joined(separator: ";"),
                    actual: actualUniqueKeys.sorted().joined(separator: ";")
                ))
            }
            let desiredChecks = Set(entity.checks.map(\.name))
            let actualChecks = Set(liveTable.checks.map(\.name))
            if desiredChecks != actualChecks {
                differences.append(.init(
                    path: "\(entity.table).checks",
                    expected: desiredChecks.sorted().joined(separator: ";"),
                    actual: actualChecks.sorted().joined(separator: ";")
                ))
            }
            let desiredForeignKeys = Set(entity.foreignKeys.map {
                "\($0.name)|\($0.columns.joined(separator: ","))|public.\($0.referencedTable)|\($0.referencedColumns.joined(separator: ","))"
            })
            let actualForeignKeys = Set(liveTable.foreignKeys.map {
                "\($0.name)|\($0.columns.joined(separator: ","))|\($0.referencedSchema).\($0.referencedTable)|\($0.referencedColumns.joined(separator: ","))"
            })
            if desiredForeignKeys != actualForeignKeys {
                differences.append(.init(
                    path: "\(entity.table).foreignKeys",
                    expected: desiredForeignKeys.sorted().joined(separator: ";"),
                    actual: actualForeignKeys.sorted().joined(separator: ";")
                ))
            }
            let desiredColumns = Set(entity.columns.map(\.name))
            for column in liveTable.columns where !desiredColumns.contains(column.name) {
                differences.append(.init(path: "\(entity.table).\(column.name)", expected: "absent", actual: "present"))
            }
        }

        let applied = Dictionary(uniqueKeysWithValues: actual.appliedMigrations.map { ($0.id, $0.checksum) })
        for migration in migrations {
            guard let checksum = applied[migration.id] else {
                differences.append(.init(path: "migrations.\(migration.id)", expected: migration.checksum, actual: "not applied"))
                continue
            }
            if checksum != migration.checksum {
                differences.append(.init(path: "migrations.\(migration.id)", expected: migration.checksum, actual: checksum ?? "legacy checksum missing"))
            }
        }
        let declaredIDs = Set(migrations.map(\.id))
        for migration in actual.appliedMigrations where !declaredIDs.contains(migration.id) {
            differences.append(.init(path: "migrations.\(migration.id)", expected: "declared", actual: "unrecognized applied migration"))
        }

        return PopulateSchemaReconciliation(
            desiredFingerprint: try desired.fingerprint(),
            actualFingerprint: try actual.fingerprint(),
            differences: differences.sorted { $0.path < $1.path }
        )
    }

    private static func normalizedType(_ type: SchemaDataType) -> String {
        switch type {
        case .text: "text"
        case .integer: "integer"
        case .bigInteger: "bigint"
        case .boolean: "boolean"
        case .uuid: "uuid"
        case .decimal: "numeric"
        case .timestampWithTimeZone: "timestamptz"
        case .binary: "bytea"
        case .postgres(let type): normalizedType(type)
        }
    }

    private static func normalizedType(_ sqlType: String) -> String {
        let type = sqlType.lowercased().split(separator: "(", maxSplits: 1).first.map(String.init) ?? sqlType.lowercased()
        return switch type.trimmingCharacters(in: .whitespaces) {
        case "int", "int4", "integer", "serial": "integer"
        case "int8", "bigint", "bigserial": "bigint"
        case "bool", "boolean": "boolean"
        case "decimal", "numeric": "numeric"
        case "timestamp with time zone", "timestamptz": "timestamptz"
        case "character varying", "varchar", "character", "char", "text": "text"
        case "bytea": "bytea"
        default: type.trimmingCharacters(in: .whitespaces)
        }
    }
}

public enum PopulateSchemaError: Error, Sendable, Equatable, CustomStringConvertible {
    case tableNotFound(String)
    case invalidSchema(String)
    case schemaDrift([PopulateSchemaDifference])

    public var description: String {
        switch self {
        case .tableNotFound(let name): "PEARFY_POPULATE_001: table '\(name)' is missing or ambiguous"
        case .invalidSchema(let detail): "PEARFY_POPULATE_002: unsupported schema: \(detail)"
        case .schemaDrift(let differences):
            "PEARFY_POPULATE_003: schema drift: " + differences.map { "\($0.path) expected \($0.expected), found \($0.actual)" }.joined(separator: "; ")
        }
    }
}

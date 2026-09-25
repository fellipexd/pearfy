import Crypto
import Foundation

public enum SchemaDataType: Codable, Equatable, Hashable, Sendable {
    case text
    case integer
    case bigInteger
    case boolean
    case uuid
    case decimal(precision: Int, scale: Int)
    case timestampWithTimeZone
    case binary
}

public enum SchemaIdentifierStrategy: String, Codable, Sendable {
    case uuidV7
    case uuidV6
    case uuidV5
    case uuidV4
    case assigned
    case autoIncrement
}

public enum SchemaDefaultValue: Codable, Equatable, Sendable {
    case text(String)
    case integer(Int64)
    case boolean(Bool)
    case currentTimestamp
}

public struct SchemaColumn: Codable, Equatable, Sendable {
    public let name: String
    public let type: SchemaDataType
    public let nullable: Bool
    public let primaryKey: Bool
    public let unique: Bool
    public let defaultValue: SchemaDefaultValue?
    /// Explicit old column name; the compiler never infers destructive renames.
    public let renamedFrom: String?
    public let identifierStrategy: SchemaIdentifierStrategy?

    public init(
        name: String,
        type: SchemaDataType,
        nullable: Bool = false,
        primaryKey: Bool = false,
        unique: Bool = false,
        defaultValue: SchemaDefaultValue? = nil,
        renamedFrom: String? = nil,
        identifierStrategy: SchemaIdentifierStrategy? = nil
    ) {
        self.name = name
        self.type = type
        self.nullable = nullable
        self.primaryKey = primaryKey
        self.unique = unique
        self.defaultValue = defaultValue
        self.renamedFrom = renamedFrom
        self.identifierStrategy = identifierStrategy
    }
}

public struct SchemaIndex: Codable, Equatable, Sendable {
    public let name: String
    public let columns: [String]
    public let unique: Bool

    public init(name: String, columns: [String], unique: Bool = false) {
        self.name = name
        self.columns = columns
        self.unique = unique
    }
}

public struct SchemaEntity: Codable, Equatable, Sendable {
    public let table: String
    public let columns: [SchemaColumn]
    public let indexes: [SchemaIndex]

    public init(table: String, columns: [SchemaColumn], indexes: [SchemaIndex] = []) {
        self.table = table
        self.columns = columns
        self.indexes = indexes
    }
}

/// Canonical, model-independent schema representation. Entity and column
/// metadata can later be emitted by `@Entity` macros and a build plugin.
public struct SchemaIR: Encodable, Equatable, Sendable {
    public let formatVersion: Int
    public let entities: [SchemaEntity]

    public init(formatVersion: Int = 1, entities: [SchemaEntity]) throws {
        guard formatVersion == 1 else { throw SchemaCompilerError.unsupportedFormatVersion(formatVersion) }
        var tableNames: Set<String> = []
        var canonicalEntities: [SchemaEntity] = []

        for entity in entities {
            _ = try SQLIdentifier(entity.table)
            guard tableNames.insert(entity.table).inserted else {
                throw SchemaCompilerError.duplicateTable(entity.table)
            }

            var columnNames: Set<String> = []
            for column in entity.columns {
                _ = try SQLIdentifier(column.name)
                guard columnNames.insert(column.name).inserted else {
                    throw SchemaCompilerError.duplicateColumn(table: entity.table, column: column.name)
                }
                if let renamedFrom = column.renamedFrom {
                    _ = try SQLIdentifier(renamedFrom)
                    guard renamedFrom != column.name else {
                        throw SchemaCompilerError.invalidRename(table: entity.table, column: column.name)
                    }
                }
                if case .decimal(let precision, let scale) = column.type,
                   precision <= 0 || scale < 0 || scale > precision {
                    throw SchemaCompilerError.invalidDecimal(table: entity.table, column: column.name)
                }
                if let strategy = column.identifierStrategy {
                    switch strategy {
                    case .uuidV7, .uuidV6, .uuidV5, .uuidV4:
                        guard column.type == .uuid else {
                            throw SchemaCompilerError.invalidIdentifierStrategy(table: entity.table, column: column.name)
                        }
                    case .autoIncrement:
                        guard (column.type == .integer || column.type == .bigInteger), column.primaryKey else {
                            throw SchemaCompilerError.invalidIdentifierStrategy(table: entity.table, column: column.name)
                        }
                    case .assigned:
                        break
                    }
                }
            }
            guard !entity.columns.isEmpty else { throw SchemaCompilerError.emptyEntity(entity.table) }

            var indexNames: Set<String> = []
            for index in entity.indexes {
                _ = try SQLIdentifier(index.name)
                guard indexNames.insert(index.name).inserted else {
                    throw SchemaCompilerError.duplicateIndex(table: entity.table, index: index.name)
                }
                guard !index.columns.isEmpty, index.columns.allSatisfy(columnNames.contains) else {
                    throw SchemaCompilerError.invalidIndex(table: entity.table, index: index.name)
                }
            }

            canonicalEntities.append(SchemaEntity(
                table: entity.table,
                columns: entity.columns.sorted { $0.name < $1.name },
                indexes: entity.indexes.sorted { $0.name < $1.name }
            ))
        }

        self.formatVersion = formatVersion
        self.entities = canonicalEntities.sorted { $0.table < $1.table }
    }

    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func fingerprint() throws -> String {
        SHA256.hash(data: try canonicalJSON()).map { String(format: "%02x", $0) }.joined()
    }
}

public struct SchemaMigrationPlan: Equatable, Sendable {
    public let fromFingerprint: String?
    public let toFingerprint: String
    public let upStatements: [String]
    public let destructiveChanges: [String]

    public var requiresDestructiveApproval: Bool { !destructiveChanges.isEmpty }
}

public enum SchemaCompilerError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedFormatVersion(Int)
    case duplicateTable(String)
    case duplicateColumn(table: String, column: String)
    case duplicateIndex(table: String, index: String)
    case emptyEntity(String)
    case invalidDecimal(table: String, column: String)
    case invalidIdentifierStrategy(table: String, column: String)
    case invalidIndex(table: String, index: String)
    case invalidRename(table: String, column: String)
    case requiredColumnNeedsDefault(table: String, column: String)
    case destructiveApprovalRequired([String])
    case unsupportedChange(table: String, column: String)
    case unsupportedIndexChange(table: String)

    public var description: String {
        switch self {
        case .unsupportedFormatVersion(let version): "PEARFY_SCHEMA_001: unsupported schema format version \(version)"
        case .duplicateTable(let table): "PEARFY_SCHEMA_002: duplicate entity table '\(table)'"
        case .duplicateColumn(let table, let column): "PEARFY_SCHEMA_003: duplicate column '\(table).\(column)'"
        case .duplicateIndex(let table, let index): "PEARFY_SCHEMA_004: duplicate index '\(table).\(index)'"
        case .emptyEntity(let table): "PEARFY_SCHEMA_005: entity '\(table)' has no columns"
        case .invalidDecimal(let table, let column): "PEARFY_SCHEMA_006: invalid decimal precision/scale for '\(table).\(column)'"
        case .invalidIndex(let table, let index): "PEARFY_SCHEMA_007: index '\(table).\(index)' has no valid columns"
        case .invalidRename(let table, let column): "PEARFY_SCHEMA_008: invalid explicit rename for '\(table).\(column)'"
        case .requiredColumnNeedsDefault(let table, let column): "PEARFY_SCHEMA_009: required column '\(table).\(column)' needs a default/backfill plan"
        case .destructiveApprovalRequired(let changes): "PEARFY_SCHEMA_010: destructive schema changes require explicit approval: \(changes.joined(separator: ", "))"
        case .unsupportedChange(let table, let column): "PEARFY_SCHEMA_011: unsupported implicit column change for '\(table).\(column)'"
        case .unsupportedIndexChange(let table): "PEARFY_SCHEMA_012: changing existing indexes on '\(table)' requires an explicit migration"
        case .invalidIdentifierStrategy(let table, let column): "PEARFY_SCHEMA_013: identifier strategy does not match '\(table).\(column)' type/key"
        }
    }
}

public struct PostgresSchemaCompiler: Sendable {
    public init() {}

    public func plan(
        from previous: SchemaIR?,
        to desired: SchemaIR,
        allowDestructiveChanges: Bool = false
    ) throws -> SchemaMigrationPlan {
        let previousTables = Dictionary(uniqueKeysWithValues: (previous?.entities ?? []).map { ($0.table, $0) })
        let desiredTables = Dictionary(uniqueKeysWithValues: desired.entities.map { ($0.table, $0) })
        var statements: [String] = []
        var destructive: [String] = []

        for entity in desired.entities {
            guard let oldEntity = previousTables[entity.table] else {
                statements.append(try createTable(entity))
                statements += try createIndexes(entity)
                continue
            }
            guard oldEntity.indexes == entity.indexes else {
                throw SchemaCompilerError.unsupportedIndexChange(table: entity.table)
            }
            try diffColumns(from: oldEntity, to: entity, statements: &statements, destructive: &destructive)
        }

        for oldEntity in previous?.entities ?? [] where desiredTables[oldEntity.table] == nil {
            destructive.append("drop table \(oldEntity.table)")
            statements.append("DROP TABLE \(try quoted(oldEntity.table))")
        }

        if !destructive.isEmpty && !allowDestructiveChanges {
            throw SchemaCompilerError.destructiveApprovalRequired(destructive.sorted())
        }

        return SchemaMigrationPlan(
            fromFingerprint: try previous?.fingerprint(),
            toFingerprint: try desired.fingerprint(),
            upStatements: statements,
            destructiveChanges: destructive.sorted()
        )
    }

    private func diffColumns(
        from oldEntity: SchemaEntity,
        to desired: SchemaEntity,
        statements: inout [String],
        destructive: inout [String]
    ) throws {
        let oldColumns = Dictionary(uniqueKeysWithValues: oldEntity.columns.map { ($0.name, $0) })
        let desiredColumns = Dictionary(uniqueKeysWithValues: desired.columns.map { ($0.name, $0) })
        var renamedOldColumns: Set<String> = []

        for column in desired.columns {
            let oldColumn: SchemaColumn?
            if let renamedFrom = column.renamedFrom {
                guard let renamedColumn = oldColumns[renamedFrom], desiredColumns[renamedFrom] == nil else {
                    throw SchemaCompilerError.invalidRename(table: desired.table, column: column.name)
                }
                renamedOldColumns.insert(renamedFrom)
                destructive.append("rename column \(desired.table).\(renamedFrom) to \(column.name)")
                statements.append(
                    "ALTER TABLE \(try quoted(desired.table)) RENAME COLUMN \(try quoted(renamedFrom)) TO \(try quoted(column.name))"
                )
                oldColumn = renamedColumn
            } else {
                oldColumn = oldColumns[column.name]
            }

            guard let oldColumn else {
                guard !column.primaryKey else {
                    throw SchemaCompilerError.unsupportedChange(table: desired.table, column: column.name)
                }
                guard column.nullable || column.defaultValue != nil else {
                    throw SchemaCompilerError.requiredColumnNeedsDefault(table: desired.table, column: column.name)
                }
                statements.append("ALTER TABLE \(try quoted(desired.table)) ADD COLUMN \(try columnDefinition(column))")
                continue
            }

            guard oldColumn.type == column.type,
                  oldColumn.primaryKey == column.primaryKey,
                  oldColumn.unique == column.unique,
                  oldColumn.nullable == column.nullable,
                  oldColumn.defaultValue == column.defaultValue else {
                throw SchemaCompilerError.unsupportedChange(table: desired.table, column: column.name)
            }
        }

        for oldColumn in oldEntity.columns where desiredColumns[oldColumn.name] == nil && !renamedOldColumns.contains(oldColumn.name) {
            destructive.append("drop column \(desired.table).\(oldColumn.name)")
            statements.append("ALTER TABLE \(try quoted(desired.table)) DROP COLUMN \(try quoted(oldColumn.name))")
        }
    }

    private func createTable(_ entity: SchemaEntity) throws -> String {
        let primaryKeyColumns = try entity.columns.filter(\.primaryKey).map { try quoted($0.name) }
        var definitions = try entity.columns.map(columnDefinition)
        if !primaryKeyColumns.isEmpty {
            definitions.append("PRIMARY KEY (\(primaryKeyColumns.joined(separator: ", ")))")
        }
        return "CREATE TABLE \(try quoted(entity.table)) (\(definitions.joined(separator: ", ")))"
    }

    private func createIndexes(_ entity: SchemaEntity) throws -> [String] {
        try entity.indexes.map { index in
            let unique = index.unique ? "UNIQUE " : ""
            let columns = try index.columns.map(quoted).joined(separator: ", ")
            return "CREATE \(unique)INDEX \(try quoted(index.name)) ON \(try quoted(entity.table)) (\(columns))"
        }
    }

    private func columnDefinition(_ column: SchemaColumn) throws -> String {
        var definition = "\(try quoted(column.name)) \(try postgresType(column.type))"
        if column.identifierStrategy == .autoIncrement {
            definition += " GENERATED BY DEFAULT AS IDENTITY"
        }
        definition += column.nullable ? " NULL" : " NOT NULL"
        if let defaultValue = column.defaultValue { definition += " DEFAULT \(try postgresDefault(defaultValue))" }
        if column.unique { definition += " UNIQUE" }
        return definition
    }

    private func postgresType(_ type: SchemaDataType) throws -> String {
        switch type {
        case .text: return "TEXT"
        case .integer: return "INTEGER"
        case .bigInteger: return "BIGINT"
        case .boolean: return "BOOLEAN"
        case .uuid: return "UUID"
        case .decimal(let precision, let scale):
            guard precision > 0, scale >= 0, scale <= precision else {
                throw SchemaCompilerError.invalidDecimal(table: "<ddl>", column: "<type>")
            }
            return "NUMERIC(\(precision), \(scale))"
        case .timestampWithTimeZone: return "TIMESTAMPTZ"
        case .binary: return "BYTEA"
        }
    }

    private func postgresDefault(_ value: SchemaDefaultValue) throws -> String {
        switch value {
        case .text(let value):
            guard !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw SQLQueryError.invalidIdentifier("NUL in schema default")
            }
            return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
        case .integer(let value): return String(value)
        case .boolean(let value): return value ? "TRUE" : "FALSE"
        case .currentTimestamp: return "CURRENT_TIMESTAMP"
        }
    }

    private func quoted(_ identifier: String) throws -> String {
        try SQLIdentifier(identifier).description
    }
}

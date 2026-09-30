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
    /// A reviewed PostgreSQL built-in or array type such as `jsonb` or `text[]`.
    case postgres(String)
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
    /// A trusted, checked-in PostgreSQL default expression.
    case sql(String)
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
    /// Explicit PostgreSQL index DDL for expression, partial, or method-specific indexes.
    public let definitionSQL: String?

    public init(name: String, columns: [String], unique: Bool = false, definitionSQL: String? = nil) {
        self.name = name
        self.columns = columns
        self.unique = unique
        self.definitionSQL = definitionSQL
    }
}

public struct SchemaCheckConstraint: Codable, Equatable, Sendable {
    public let name: String
    public let expression: String

    public init(name: String, expression: String) {
        self.name = name
        self.expression = expression
    }
}

public struct SchemaUniqueConstraint: Codable, Equatable, Sendable {
    public let name: String
    public let columns: [String]

    public init(name: String, columns: [String]) {
        self.name = name
        self.columns = columns
    }
}

public enum SchemaReferentialAction: String, Codable, Sendable {
    case noAction = "NO ACTION"
    case restrict = "RESTRICT"
    case cascade = "CASCADE"
    case setNull = "SET NULL"
    case setDefault = "SET DEFAULT"
}

public struct SchemaForeignKey: Codable, Equatable, Sendable {
    public let name: String
    public let columns: [String]
    public let referencedTable: String
    public let referencedColumns: [String]
    public let onUpdate: SchemaReferentialAction
    public let onDelete: SchemaReferentialAction
    /// PostgreSQL 15+ allows a subset of referencing columns for SET NULL.
    public let setNullColumns: [String]

    public init(
        name: String,
        columns: [String],
        referencedTable: String,
        referencedColumns: [String],
        onUpdate: SchemaReferentialAction = .noAction,
        onDelete: SchemaReferentialAction = .noAction,
        setNullColumns: [String] = []
    ) {
        self.name = name
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.setNullColumns = setNullColumns
    }
}

public struct SchemaEntity: Codable, Equatable, Sendable {
    public let table: String
    public let columns: [SchemaColumn]
    public let indexes: [SchemaIndex]
    public let primaryKey: [String]
    public let checks: [SchemaCheckConstraint]
    public let uniqueConstraints: [SchemaUniqueConstraint]
    public let foreignKeys: [SchemaForeignKey]
    /// Reviewed table constraints that are not column-level metadata.
    public let supplementalSQL: [String]

    public init(
        table: String,
        columns: [SchemaColumn],
        indexes: [SchemaIndex] = [],
        primaryKey: [String] = [],
        checks: [SchemaCheckConstraint] = [],
        uniqueConstraints: [SchemaUniqueConstraint] = [],
        foreignKeys: [SchemaForeignKey] = [],
        supplementalSQL: [String] = []
    ) {
        self.table = table
        self.columns = columns
        self.indexes = indexes
        self.primaryKey = primaryKey
        self.checks = checks
        self.uniqueConstraints = uniqueConstraints
        self.foreignKeys = foreignKeys
        self.supplementalSQL = supplementalSQL
    }

    private enum CodingKeys: String, CodingKey {
        case table
        case columns
        case indexes
        case primaryKey
        case checks
        case uniqueConstraints
        case foreignKeys
        case supplementalSQL
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            table: try container.decode(String.self, forKey: .table),
            columns: try container.decode([SchemaColumn].self, forKey: .columns),
            indexes: try container.decodeIfPresent([SchemaIndex].self, forKey: .indexes) ?? [],
            primaryKey: try container.decodeIfPresent([String].self, forKey: .primaryKey) ?? [],
            checks: try container.decodeIfPresent([SchemaCheckConstraint].self, forKey: .checks) ?? [],
            uniqueConstraints: try container.decodeIfPresent([SchemaUniqueConstraint].self, forKey: .uniqueConstraints) ?? [],
            foreignKeys: try container.decodeIfPresent([SchemaForeignKey].self, forKey: .foreignKeys) ?? [],
            supplementalSQL: try container.decodeIfPresent([String].self, forKey: .supplementalSQL) ?? []
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(table, forKey: .table)
        try container.encode(columns, forKey: .columns)
        try container.encode(indexes, forKey: .indexes)
        try container.encode(primaryKey, forKey: .primaryKey)
        try container.encode(checks, forKey: .checks)
        try container.encode(uniqueConstraints, forKey: .uniqueConstraints)
        try container.encode(foreignKeys, forKey: .foreignKeys)
        try container.encode(supplementalSQL, forKey: .supplementalSQL)
    }
}

/// Canonical, model-independent schema representation. Entity and column
/// metadata can later be emitted by `@Entity` macros and a build plugin.
public struct SchemaIR: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let entities: [SchemaEntity]
    /// SQL model elements needed before tables, such as extensions/functions.
    public let preTableSQL: [String]
    /// SQL model elements needed after tables, such as triggers and seed rows.
    public let postTableSQL: [String]

    public init(
        formatVersion: Int = 1,
        entities: [SchemaEntity],
        preTableSQL: [String] = [],
        postTableSQL: [String] = []
    ) throws {
        guard formatVersion == 1 else { throw SchemaCompilerError.unsupportedFormatVersion(formatVersion) }
        guard (preTableSQL + postTableSQL + entities.flatMap(\.supplementalSQL))
            .allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.unicodeScalars.contains(where: { $0.value == 0 }) }) else {
            throw SchemaCompilerError.invalidModelSQL
        }
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
                if case .postgres(let type) = column.type, !Self.isSafePostgresType(type) {
                    throw SchemaCompilerError.invalidPostgresType(table: entity.table, column: column.name)
                }
                if case .sql(let expression) = column.defaultValue,
                   !Self.isSafeDefaultExpression(expression) {
                    throw SchemaCompilerError.invalidDefault(table: entity.table, column: column.name)
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
            let primaryKey = entity.primaryKey.isEmpty
                ? entity.columns.filter(\.primaryKey).map(\.name)
                : entity.primaryKey
            guard Set(primaryKey).count == primaryKey.count,
                  primaryKey.allSatisfy(columnNames.contains) else {
                throw SchemaCompilerError.invalidPrimaryKey(entity.table)
            }
            if !entity.primaryKey.isEmpty,
               entity.columns.contains(where: \.primaryKey),
               entity.columns.filter(\.primaryKey).map(\.name) != entity.primaryKey {
                throw SchemaCompilerError.invalidPrimaryKey(entity.table)
            }

            var indexNames: Set<String> = []
            for index in entity.indexes {
                _ = try SQLIdentifier(index.name)
                guard indexNames.insert(index.name).inserted else {
                    throw SchemaCompilerError.duplicateIndex(table: entity.table, index: index.name)
                }
                if let definitionSQL = index.definitionSQL {
                    guard Self.isSafeIndexDefinition(definitionSQL, expectedName: index.name) else {
                        throw SchemaCompilerError.invalidIndex(table: entity.table, index: index.name)
                    }
                } else {
                    guard !index.columns.isEmpty, index.columns.allSatisfy(columnNames.contains) else {
                        throw SchemaCompilerError.invalidIndex(table: entity.table, index: index.name)
                    }
                }
            }

            for check in entity.checks {
                _ = try SQLIdentifier(check.name)
                guard Self.isSafeExpression(check.expression) else {
                    throw SchemaCompilerError.invalidConstraint(table: entity.table, constraint: check.name)
                }
            }
            for unique in entity.uniqueConstraints {
                _ = try SQLIdentifier(unique.name)
                guard !unique.columns.isEmpty, unique.columns.allSatisfy(columnNames.contains) else {
                    throw SchemaCompilerError.invalidConstraint(table: entity.table, constraint: unique.name)
                }
            }
            for foreignKey in entity.foreignKeys {
                _ = try SQLIdentifier(foreignKey.name)
                _ = try SQLIdentifier(foreignKey.referencedTable)
                guard !foreignKey.columns.isEmpty,
                      foreignKey.columns.count == foreignKey.referencedColumns.count,
                      foreignKey.columns.allSatisfy(columnNames.contains),
                      foreignKey.referencedColumns.allSatisfy({ (try? SQLIdentifier($0)) != nil }),
                      foreignKey.setNullColumns.allSatisfy(foreignKey.columns.contains),
                      foreignKey.setNullColumns.isEmpty || foreignKey.onDelete == .setNull else {
                    throw SchemaCompilerError.invalidConstraint(table: entity.table, constraint: foreignKey.name)
                }
            }

            canonicalEntities.append(SchemaEntity(
                table: entity.table,
                columns: entity.columns.sorted { $0.name < $1.name },
                indexes: entity.indexes.sorted { $0.name < $1.name },
                primaryKey: primaryKey,
                checks: entity.checks.sorted { $0.name < $1.name },
                uniqueConstraints: entity.uniqueConstraints.sorted { $0.name < $1.name },
                foreignKeys: entity.foreignKeys.sorted { $0.name < $1.name },
                supplementalSQL: entity.supplementalSQL
            ))
        }

        self.formatVersion = formatVersion
        self.entities = canonicalEntities.sorted { $0.table < $1.table }
        self.preTableSQL = preTableSQL
        self.postTableSQL = postTableSQL
    }

    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func fingerprint() throws -> String {
        SHA256.hash(data: try canonicalJSON()).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case entities
        case preTableSQL
        case postTableSQL
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            formatVersion: container.decode(Int.self, forKey: .formatVersion),
            entities: container.decode([SchemaEntity].self, forKey: .entities),
            preTableSQL: container.decodeIfPresent([String].self, forKey: .preTableSQL) ?? [],
            postTableSQL: container.decodeIfPresent([String].self, forKey: .postTableSQL) ?? []
        )
    }

    private static func isSafePostgresType(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == 95 || byte == 32 || byte == 40 || byte == 41 || byte == 44 || byte == 91 || byte == 93
        }
    }

    private static func isSafeDefaultExpression(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
            && !value.contains(";")
    }

    private static func isSafeExpression(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
            && !value.contains(";")
    }

    private static func isSafeIndexDefinition(_ value: String, expectedName: String) -> Bool {
        let definition = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercased = definition.uppercased()
        return (uppercased.hasPrefix("CREATE INDEX ") || uppercased.hasPrefix("CREATE UNIQUE INDEX "))
            && definition.contains(expectedName)
            && !definition.unicodeScalars.contains(where: { $0.value == 0 })
            && !definition.contains(";")
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
    case invalidPostgresType(table: String, column: String)
    case invalidDefault(table: String, column: String)
    case invalidPrimaryKey(String)
    case invalidModelSQL
    case invalidConstraint(table: String, constraint: String)

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
        case .invalidPostgresType(let table, let column): "PEARFY_SCHEMA_014: unsafe PostgreSQL type for '\(table).\(column)'"
        case .invalidDefault(let table, let column): "PEARFY_SCHEMA_015: unsafe SQL default for '\(table).\(column)'"
        case .invalidPrimaryKey(let table): "PEARFY_SCHEMA_016: invalid primary-key metadata for '\(table)'"
        case .invalidModelSQL: "PEARFY_SCHEMA_017: schema model contains empty or NUL-bearing SQL"
        case .invalidConstraint(let table, let constraint): "PEARFY_SCHEMA_018: invalid constraint '\(constraint)' on '\(table)'"
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
        var statements: [String] = previous == nil ? desired.preTableSQL : []
        var destructive: [String] = []
        var newEntities: [SchemaEntity] = []

        for entity in desired.entities {
            guard let oldEntity = previousTables[entity.table] else {
                statements.append(try createTable(entity))
                newEntities.append(entity)
                continue
            }
            guard oldEntity.indexes == entity.indexes else {
                throw SchemaCompilerError.unsupportedIndexChange(table: entity.table)
            }
            try diffColumns(from: oldEntity, to: entity, statements: &statements, destructive: &destructive)
        }

        for entity in newEntities {
            statements += try createIndexes(entity)
        }
        for entity in newEntities {
            statements += try createConstraints(entity)
        }
        for entity in newEntities {
            statements += try createForeignKeys(entity)
        }
        for entity in newEntities {
            statements += entity.supplementalSQL
        }

        for oldEntity in previous?.entities ?? [] where desiredTables[oldEntity.table] == nil {
            destructive.append("drop table \(oldEntity.table)")
            statements.append("DROP TABLE \(try quoted(oldEntity.table))")
        }

        if previous == nil {
            statements += desired.postTableSQL
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
        let modelPrimaryKey = entity.primaryKey.isEmpty
            ? entity.columns.filter(\.primaryKey).map(\.name)
            : entity.primaryKey
        let primaryKeyColumns = try modelPrimaryKey.map(quoted)
        var definitions = try entity.columns.map(columnDefinition)
        if !primaryKeyColumns.isEmpty {
            definitions.append("PRIMARY KEY (\(primaryKeyColumns.joined(separator: ", ")))")
        }
        return "CREATE TABLE \(try quoted(entity.table)) (\(definitions.joined(separator: ", ")))"
    }

    private func createIndexes(_ entity: SchemaEntity) throws -> [String] {
        try entity.indexes.map { index in
            if let definitionSQL = index.definitionSQL { return definitionSQL }
            let unique = index.unique ? "UNIQUE " : ""
            let columns = try index.columns.map(quoted).joined(separator: ", ")
            return "CREATE \(unique)INDEX \(try quoted(index.name)) ON \(try quoted(entity.table)) (\(columns))"
        }
    }

    private func createConstraints(_ entity: SchemaEntity) throws -> [String] {
        var statements: [String] = []
        for check in entity.checks {
            statements.append("ALTER TABLE \(try quoted(entity.table)) ADD CONSTRAINT \(try quoted(check.name)) CHECK (\(check.expression))")
        }
        for unique in entity.uniqueConstraints {
            let columns = try unique.columns.map(quoted).joined(separator: ", ")
            statements.append("ALTER TABLE \(try quoted(entity.table)) ADD CONSTRAINT \(try quoted(unique.name)) UNIQUE (\(columns))")
        }
        return statements
    }

    private func createForeignKeys(_ entity: SchemaEntity) throws -> [String] {
        var statements: [String] = []
        for foreignKey in entity.foreignKeys {
            let columns = try foreignKey.columns.map(quoted).joined(separator: ", ")
            let referencedColumns = try foreignKey.referencedColumns.map(quoted).joined(separator: ", ")
            var statement = "ALTER TABLE \(try quoted(entity.table)) ADD CONSTRAINT \(try quoted(foreignKey.name)) FOREIGN KEY (\(columns)) REFERENCES \(try quoted(foreignKey.referencedTable)) (\(referencedColumns))"
            if foreignKey.onUpdate != .noAction { statement += " ON UPDATE \(foreignKey.onUpdate.rawValue)" }
            if foreignKey.onDelete != .noAction {
                statement += " ON DELETE \(foreignKey.onDelete.rawValue)"
                if foreignKey.onDelete == .setNull, !foreignKey.setNullColumns.isEmpty {
                    statement += " (\(try foreignKey.setNullColumns.map(quoted).joined(separator: ", ")))"
                }
            }
            statements.append(statement)
        }
        return statements
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
        case .postgres(let value): return value
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
        case .sql(let expression): return expression
        }
    }

    private func quoted(_ identifier: String) throws -> String {
        try SQLIdentifier(identifier).description
    }
}

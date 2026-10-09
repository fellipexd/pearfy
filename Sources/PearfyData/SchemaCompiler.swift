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

public enum SchemaRelationshipKind: String, Codable, Sendable {
    case manyToOne
    case oneToOne
    case oneToMany
    case manyToMany
}

/// Declarative association metadata. It describes relational schema only; it
/// does not load related values or provide persistence behavior.
public struct SchemaRelationship: Codable, Equatable, Sendable {
    public let field: String
    public let kind: SchemaRelationshipKind
    public let targetTable: String
    public let mappedBy: String?
    public let column: String?
    public let referencedColumn: String
    public let foreignKeyName: String?
    public let nullable: Bool
    /// Adds this owning foreign-key column to the entity primary key.
    public let primaryKey: Bool
    public let onUpdate: SchemaReferentialAction
    public let onDelete: SchemaReferentialAction
    public let joinTable: String?
    public let joinColumn: String?
    public let inverseJoinColumn: String?
    public let inverseReferencedColumn: String?
    public let inverseForeignKeyName: String?

    public init(
        field: String,
        kind: SchemaRelationshipKind,
        targetTable: String,
        mappedBy: String? = nil,
        column: String? = nil,
        referencedColumn: String = "id",
        foreignKeyName: String? = nil,
        nullable: Bool = false,
        primaryKey: Bool = false,
        onUpdate: SchemaReferentialAction = .noAction,
        onDelete: SchemaReferentialAction = .noAction,
        joinTable: String? = nil,
        joinColumn: String? = nil,
        inverseJoinColumn: String? = nil,
        inverseReferencedColumn: String? = nil,
        inverseForeignKeyName: String? = nil
    ) {
        self.field = field
        self.kind = kind
        self.targetTable = targetTable
        self.mappedBy = mappedBy
        self.column = column
        self.referencedColumn = referencedColumn
        self.foreignKeyName = foreignKeyName
        self.nullable = nullable
        self.primaryKey = primaryKey
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.joinTable = joinTable
        self.joinColumn = joinColumn
        self.inverseJoinColumn = inverseJoinColumn
        self.inverseReferencedColumn = inverseReferencedColumn
        self.inverseForeignKeyName = inverseForeignKeyName
    }

    private enum CodingKeys: String, CodingKey {
        case field, kind, targetTable, mappedBy, column, referencedColumn, foreignKeyName
        case nullable, primaryKey, onUpdate, onDelete, joinTable, joinColumn, inverseJoinColumn
        case inverseReferencedColumn, inverseForeignKeyName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            field: try container.decode(String.self, forKey: .field),
            kind: try container.decode(SchemaRelationshipKind.self, forKey: .kind),
            targetTable: try container.decode(String.self, forKey: .targetTable),
            mappedBy: try container.decodeIfPresent(String.self, forKey: .mappedBy),
            column: try container.decodeIfPresent(String.self, forKey: .column),
            referencedColumn: try container.decode(String.self, forKey: .referencedColumn),
            foreignKeyName: try container.decodeIfPresent(String.self, forKey: .foreignKeyName),
            nullable: try container.decode(Bool.self, forKey: .nullable),
            primaryKey: try container.decodeIfPresent(Bool.self, forKey: .primaryKey) ?? false,
            onUpdate: try container.decode(SchemaReferentialAction.self, forKey: .onUpdate),
            onDelete: try container.decode(SchemaReferentialAction.self, forKey: .onDelete),
            joinTable: try container.decodeIfPresent(String.self, forKey: .joinTable),
            joinColumn: try container.decodeIfPresent(String.self, forKey: .joinColumn),
            inverseJoinColumn: try container.decodeIfPresent(String.self, forKey: .inverseJoinColumn),
            inverseReferencedColumn: try container.decodeIfPresent(String.self, forKey: .inverseReferencedColumn),
            inverseForeignKeyName: try container.decodeIfPresent(String.self, forKey: .inverseForeignKeyName)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(field, forKey: .field)
        try container.encode(kind, forKey: .kind)
        try container.encode(targetTable, forKey: .targetTable)
        try container.encodeIfPresent(mappedBy, forKey: .mappedBy)
        try container.encodeIfPresent(column, forKey: .column)
        try container.encode(referencedColumn, forKey: .referencedColumn)
        try container.encodeIfPresent(foreignKeyName, forKey: .foreignKeyName)
        try container.encode(nullable, forKey: .nullable)
        if primaryKey { try container.encode(true, forKey: .primaryKey) }
        try container.encode(onUpdate, forKey: .onUpdate)
        try container.encode(onDelete, forKey: .onDelete)
        try container.encodeIfPresent(joinTable, forKey: .joinTable)
        try container.encodeIfPresent(joinColumn, forKey: .joinColumn)
        try container.encodeIfPresent(inverseJoinColumn, forKey: .inverseJoinColumn)
        try container.encodeIfPresent(inverseReferencedColumn, forKey: .inverseReferencedColumn)
        try container.encodeIfPresent(inverseForeignKeyName, forKey: .inverseForeignKeyName)
    }
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
    public let relationships: [SchemaRelationship]
    /// True only for deterministic junction tables synthesized from @ManyToMany.
    public let relationshipJoinTable: Bool
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
        supplementalSQL: [String] = [],
        relationships: [SchemaRelationship] = [],
        relationshipJoinTable: Bool = false
    ) {
        self.table = table
        self.columns = columns
        self.indexes = indexes
        self.primaryKey = primaryKey
        self.checks = checks
        self.uniqueConstraints = uniqueConstraints
        self.foreignKeys = foreignKeys
        self.supplementalSQL = supplementalSQL
        self.relationships = relationships
        self.relationshipJoinTable = relationshipJoinTable
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
        case relationships
        case relationshipJoinTable
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
            supplementalSQL: try container.decodeIfPresent([String].self, forKey: .supplementalSQL) ?? [],
            relationships: try container.decodeIfPresent([SchemaRelationship].self, forKey: .relationships) ?? [],
            relationshipJoinTable: try container.decodeIfPresent(Bool.self, forKey: .relationshipJoinTable) ?? false
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
        if !relationships.isEmpty {
            try container.encode(relationships, forKey: .relationships)
        }
        if relationshipJoinTable { try container.encode(true, forKey: .relationshipJoinTable) }
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
        var entitiesByTable: [String: SchemaEntity] = [:]
        for entity in entities {
            guard tableNames.insert(entity.table).inserted else {
                throw SchemaCompilerError.duplicateTable(entity.table)
            }
            entitiesByTable[entity.table] = entity
        }
        var inverseMappings: Set<String> = []
        var generatedJoinTables: [String: SchemaEntity] = [:]

        for entity in entities {
            _ = try SQLIdentifier(entity.table)
            if entity.relationshipJoinTable && !entity.relationships.isEmpty {
                throw SchemaCompilerError.invalidRelationship(table: entity.table, field: "*", reason: "generated relationship join tables cannot declare relationships")
            }

            var materializedColumns = entity.columns
            var materializedForeignKeys = entity.foreignKeys
            var relationshipFields: Set<String> = []
            for relationship in entity.relationships {
                do { _ = try SQLIdentifier(relationship.field) }
                catch { throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "invalid relationship property name") }
                guard relationshipFields.insert(relationship.field).inserted else {
                    throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "duplicate relationship property")
                }
                guard let target = entitiesByTable[relationship.targetTable] else {
                    throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "target table '\(relationship.targetTable)' does not exist in this schema")
                }
                guard !target.relationshipJoinTable else {
                    throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "relationship target cannot be a generated junction table")
                }
                _ = try SQLIdentifier(relationship.targetTable)

                let owning: Bool
                switch relationship.kind {
                case .manyToOne:
                    guard !relationship.primaryKey || relationship.mappedBy == nil else {
                        throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "inverse relationships cannot participate in a primary key")
                    }
                    guard relationship.mappedBy == nil else {
                        throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "@ManyToOne must own its foreign key and cannot use mappedBy")
                    }
                    owning = true
                case .oneToOne:
                    owning = relationship.mappedBy == nil
                    if relationship.primaryKey && !owning {
                        throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "inverse relationships cannot participate in a primary key")
                    }
                    if !owning {
                        guard relationship.column == nil, relationship.foreignKeyName == nil,
                              relationship.onUpdate == .noAction, relationship.onDelete == .noAction,
                              relationship.referencedColumn == "id" else {
                            throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "inverse @OneToOne cannot configure foreign-key options")
                        }
                    }
                case .oneToMany:
                    guard !relationship.primaryKey else {
                        throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "inverse relationships cannot participate in a primary key")
                    }
                    guard let mappedBy = relationship.mappedBy, !mappedBy.isEmpty else {
                        throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "inverse @OneToMany requires mappedBy")
                    }
                    guard relationship.column == nil, relationship.foreignKeyName == nil,
                          relationship.onUpdate == .noAction, relationship.onDelete == .noAction,
                          relationship.referencedColumn == "id" else {
                        throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "@OneToMany is inverse-only; configure the foreign key on the owning @ManyToOne")
                    }
                    owning = false
                case .manyToMany:
                    guard !relationship.primaryKey else {
                        throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "many-to-many relationships cannot directly participate in an entity primary key")
                    }
                    owning = relationship.mappedBy == nil
                    if !owning {
                        guard relationship.column == nil, relationship.foreignKeyName == nil,
                              relationship.joinTable == nil, relationship.joinColumn == nil,
                              relationship.inverseJoinColumn == nil, relationship.inverseForeignKeyName == nil,
                              relationship.onUpdate == .noAction, relationship.onDelete == .noAction,
                              relationship.referencedColumn == "id", relationship.inverseReferencedColumn == nil else {
                            throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "inverse @ManyToMany cannot configure join-table or foreign-key options")
                        }
                    } else {
                        guard relationship.column == nil,
                              !relationship.nullable, relationship.referencedColumn == "id" else {
                            throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "@ManyToMany uses non-null join-table keys; configure join columns with joinColumn and inverseJoinColumn")
                        }
                    }
                }

                if !owning {
                    guard let mappedBy = relationship.mappedBy,
                          let owner = target.relationships.first(where: { $0.field == mappedBy }) else {
                        throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "mappedBy does not name a relationship on '\(relationship.targetTable)'")
                    }
                    let expectedOwnerKind: SchemaRelationshipKind = switch relationship.kind {
                    case .oneToMany: .manyToOne
                    case .oneToOne: .oneToOne
                    case .manyToMany: .manyToMany
                    case .manyToOne: .manyToOne
                    }
                    guard owner.kind == expectedOwnerKind, owner.mappedBy == nil, owner.targetTable == entity.table else {
                        throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "mappedBy must reference the owning \(expectedOwnerKind.rawValue) relationship back to '\(entity.table)'")
                    }
                    let mappingKey = "\(relationship.targetTable).\(mappedBy)"
                    guard inverseMappings.insert(mappingKey).inserted else {
                        throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "the owning relationship is already mapped by another inverse property")
                    }
                    continue
                }

                if relationship.kind == .manyToMany {
                    let inverseReferencedColumn = relationship.inverseReferencedColumn ?? "id"
                    let sourceReferencedColumn = relationship.referencedColumn
                    let sourceID = try Self.relationshipReferenceColumn(sourceReferencedColumn, entity: entity, targetName: entity.table, field: relationship.field)
                    let targetID = try Self.relationshipReferenceColumn(inverseReferencedColumn, entity: target, targetName: target.table, field: relationship.field)
                    let joinTable = relationship.joinTable ?? "\(entity.table)_\(target.table)"
                    let joinColumn = relationship.joinColumn ?? "\(Self.snakeCase(entity.table))_id"
                    let inverseJoinColumn = relationship.inverseJoinColumn ?? "\(Self.snakeCase(target.table))_id"
                    do { _ = try SQLIdentifier(joinTable); _ = try SQLIdentifier(joinColumn); _ = try SQLIdentifier(inverseJoinColumn) }
                    catch { throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "invalid join-table identifier") }
                    guard joinColumn != inverseJoinColumn else {
                        throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "joinColumn and inverseJoinColumn must be distinct")
                    }
                    if relationship.onDelete == .setNull || relationship.onUpdate == .setNull || relationship.onDelete == .setDefault || relationship.onUpdate == .setDefault {
                        throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "join-table foreign keys are non-null and do not support SET NULL or SET DEFAULT")
                    }
                    let joinFKName = relationship.foreignKeyName ?? "fk_\(joinTable)_\(joinColumn)"
                    let inverseFKName = relationship.inverseForeignKeyName ?? "fk_\(joinTable)_\(inverseJoinColumn)"
                    do { _ = try SQLIdentifier(joinFKName); _ = try SQLIdentifier(inverseFKName) }
                    catch { throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "invalid join-table foreign-key identifier") }
                    guard joinFKName != inverseFKName else {
                        throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "join-table foreign-key names must be distinct")
                    }
                    let synthesized = SchemaEntity(
                        table: joinTable,
                        columns: [
                            SchemaColumn(name: joinColumn, type: sourceID.type),
                            SchemaColumn(name: inverseJoinColumn, type: targetID.type)
                        ].sorted { $0.name < $1.name },
                        primaryKey: [joinColumn, inverseJoinColumn],
                        foreignKeys: [
                            SchemaForeignKey(name: joinFKName, columns: [joinColumn], referencedTable: entity.table, referencedColumns: [sourceReferencedColumn], onUpdate: relationship.onUpdate, onDelete: relationship.onDelete),
                            SchemaForeignKey(name: inverseFKName, columns: [inverseJoinColumn], referencedTable: target.table, referencedColumns: [inverseReferencedColumn], onUpdate: relationship.onUpdate, onDelete: relationship.onDelete)
                        ].sorted { $0.name < $1.name },
                        relationshipJoinTable: true
                    )
                    if let existing = entitiesByTable[joinTable] {
                        guard existing.relationshipJoinTable,
                              existing.columns.sorted(by: { $0.name < $1.name }) == synthesized.columns.sorted(by: { $0.name < $1.name }),
                              existing.primaryKey == synthesized.primaryKey,
                              existing.foreignKeys.sorted(by: { $0.name < $1.name }) == synthesized.foreignKeys.sorted(by: { $0.name < $1.name }) else {
                            throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "join table '\(joinTable)' conflicts with an existing schema entity")
                        }
                    }
                    if let existing = generatedJoinTables[joinTable] {
                        guard existing == synthesized else {
                            throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "multiple relationships generate conflicting join table '\(joinTable)'; configure distinct joinTable names")
                        }
                    } else {
                        generatedJoinTables[joinTable] = synthesized
                    }
                    continue
                }

                if relationship.primaryKey && relationship.nullable {
                    throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "a relationship primary-key column must be non-null")
                }

                _ = try SQLIdentifier(relationship.referencedColumn)
                guard let referenced = target.columns.first(where: { $0.name == relationship.referencedColumn }) else {
                    throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "referenced column '\(relationship.targetTable).\(relationship.referencedColumn)' does not exist")
                }
                let referenceIsUnique = referenced.primaryKey || target.primaryKey.contains(relationship.referencedColumn) || referenced.unique
                    || target.uniqueConstraints.contains { $0.columns == [relationship.referencedColumn] }
                    || target.indexes.contains { $0.unique && $0.columns == [relationship.referencedColumn] }
                guard referenceIsUnique else {
                    throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "referenced column must be a primary key or uniquely constrained")
                }
                if (relationship.onDelete == .setNull || relationship.onUpdate == .setNull) && !relationship.nullable {
                    throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "SET NULL requires nullable: true")
                }

                let columnName = relationship.column ?? Self.defaultRelationshipColumn(for: relationship.field)
                _ = try SQLIdentifier(columnName)
                let oneToOne = relationship.kind == .oneToOne
                let existingColumn = materializedColumns.first(where: { $0.name == columnName })
                if relationship.onDelete == .setDefault || relationship.onUpdate == .setDefault {
                    guard existingColumn?.defaultValue != nil else {
                        throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "SET DEFAULT requires an explicitly modeled foreign-key column with a default value")
                    }
                }
                let desiredColumn = SchemaColumn(
                    name: columnName,
                    type: referenced.type,
                    nullable: relationship.nullable,
                    primaryKey: relationship.primaryKey,
                    unique: oneToOne && !relationship.primaryKey
                )
                if let existing = existingColumn {
                    guard existing.type == desiredColumn.type, existing.nullable == desiredColumn.nullable,
                          existing.unique == desiredColumn.unique,
                          existing.primaryKey == desiredColumn.primaryKey || relationship.primaryKey else {
                        throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "configured foreign-key column conflicts with existing column metadata")
                    }
                    if relationship.primaryKey, !existing.primaryKey,
                       let index = materializedColumns.firstIndex(where: { $0.name == columnName }) {
                        materializedColumns[index] = SchemaColumn(
                            name: existing.name,
                            type: existing.type,
                            nullable: existing.nullable,
                            primaryKey: true,
                            unique: existing.unique,
                            defaultValue: existing.defaultValue,
                            renamedFrom: existing.renamedFrom,
                            identifierStrategy: existing.identifierStrategy
                        )
                    }
                } else {
                    materializedColumns.append(desiredColumn)
                }

                let foreignKeyName = relationship.foreignKeyName ?? "fk_\(entity.table)_\(columnName)"
                _ = try SQLIdentifier(foreignKeyName)
                let generatedForeignKey = SchemaForeignKey(
                    name: foreignKeyName,
                    columns: [columnName],
                    referencedTable: relationship.targetTable,
                    referencedColumns: [relationship.referencedColumn],
                    onUpdate: relationship.onUpdate,
                    onDelete: relationship.onDelete,
                    setNullColumns: relationship.onDelete == .setNull ? [columnName] : []
                )
                if let existing = materializedForeignKeys.first(where: { $0.name == foreignKeyName }) {
                    guard existing == generatedForeignKey else {
                        throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "foreign-key name conflicts with existing constraint metadata")
                    }
                } else if materializedForeignKeys.contains(where: { $0.columns == [columnName] }) {
                    throw SchemaCompilerError.invalidRelationship(table: entity.table, field: relationship.field, reason: "foreign-key column is already owned by another constraint")
                } else {
                    materializedForeignKeys.append(generatedForeignKey)
                }
            }

            var columnNames: Set<String> = []
            for column in materializedColumns {
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
            guard !materializedColumns.isEmpty else { throw SchemaCompilerError.emptyEntity(entity.table) }
            let relationshipPrimaryKeyColumns = entity.relationships
                .filter(\.primaryKey)
                .compactMap { relationship in
                    relationship.column ?? Self.defaultRelationshipColumn(for: relationship.field)
                }
            let scalarPrimaryKeyColumns = entity.primaryKey.isEmpty
                ? materializedColumns.filter(\.primaryKey).map(\.name)
                : entity.primaryKey
            let primaryKey = relationshipPrimaryKeyColumns
                + scalarPrimaryKeyColumns.filter { !relationshipPrimaryKeyColumns.contains($0) }
            guard Set(primaryKey).count == primaryKey.count,
                  primaryKey.allSatisfy(columnNames.contains),
                  primaryKey.allSatisfy({ name in materializedColumns.first(where: { $0.name == name })?.nullable == false }) else {
                throw SchemaCompilerError.invalidPrimaryKey(entity.table)
            }
            if !entity.primaryKey.isEmpty,
               materializedColumns.contains(where: \.primaryKey),
               (relationshipPrimaryKeyColumns.isEmpty
                ? materializedColumns.filter(\.primaryKey).map(\.name) != entity.primaryKey
                : Set(materializedColumns.filter(\.primaryKey).map(\.name)) != Set(primaryKey)) {
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
            for foreignKey in materializedForeignKeys {
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
                columns: materializedColumns.sorted { $0.name < $1.name },
                indexes: entity.indexes.sorted { $0.name < $1.name },
                primaryKey: primaryKey,
                checks: entity.checks.sorted { $0.name < $1.name },
                uniqueConstraints: entity.uniqueConstraints.sorted { $0.name < $1.name },
                foreignKeys: materializedForeignKeys.sorted { $0.name < $1.name },
                supplementalSQL: entity.supplementalSQL,
                relationships: entity.relationships.sorted { $0.field < $1.field },
                relationshipJoinTable: entity.relationshipJoinTable
            ))
        }

        for (table, joinTable) in generatedJoinTables where entitiesByTable[table] == nil {
            canonicalEntities.append(joinTable)
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

    private static func defaultRelationshipColumn(for field: String) -> String {
        var result = ""
        for scalar in field.unicodeScalars {
            if CharacterSet.uppercaseLetters.contains(scalar) {
                if !result.isEmpty { result.append("_") }
                result.append(String(scalar).lowercased())
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return "\(result)_id"
    }

    private static func snakeCase(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            if CharacterSet.uppercaseLetters.contains(scalar) {
                if !result.isEmpty { result.append("_") }
                result.append(String(scalar).lowercased())
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func relationshipReferenceColumn(
        _ name: String,
        entity: SchemaEntity,
        targetName: String,
        field: String
    ) throws -> SchemaColumn {
        do { _ = try SQLIdentifier(name) }
        catch { throw SchemaCompilerError.invalidRelationship(table: entity.table, field: field, reason: "invalid referenced column '\(name)'") }
        guard let column = entity.columns.first(where: { $0.name == name }) else {
            throw SchemaCompilerError.invalidRelationship(table: entity.table, field: field, reason: "referenced column '\(targetName).\(name)' does not exist")
        }
        let isUnique = column.primaryKey || entity.primaryKey.contains(name) || column.unique
            || entity.uniqueConstraints.contains { $0.columns == [name] }
            || entity.indexes.contains { $0.unique && $0.columns == [name] }
        guard isUnique else {
            throw SchemaCompilerError.invalidRelationship(table: entity.table, field: field, reason: "referenced column '\(targetName).\(name)' must be a primary key or uniquely constrained")
        }
        return column
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
    case unsupportedPrimaryKeyChange(table: String)
    case unsupportedIndexChange(table: String)
    case invalidPostgresType(table: String, column: String)
    case invalidDefault(table: String, column: String)
    case invalidPrimaryKey(String)
    case invalidModelSQL
    case invalidConstraint(table: String, constraint: String)
    case invalidRelationship(table: String, field: String, reason: String)
    case unsupportedRelationshipChange(table: String, constraint: String)

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
        case .unsupportedPrimaryKeyChange(let table): "PEARFY_SCHEMA_021: changing the primary key of '\(table)' requires an explicit migration"
        case .unsupportedIndexChange(let table): "PEARFY_SCHEMA_012: changing existing indexes on '\(table)' requires an explicit migration"
        case .invalidIdentifierStrategy(let table, let column): "PEARFY_SCHEMA_013: identifier strategy does not match '\(table).\(column)' type/key"
        case .invalidPostgresType(let table, let column): "PEARFY_SCHEMA_014: unsafe PostgreSQL type for '\(table).\(column)'"
        case .invalidDefault(let table, let column): "PEARFY_SCHEMA_015: unsafe SQL default for '\(table).\(column)'"
        case .invalidPrimaryKey(let table): "PEARFY_SCHEMA_016: invalid primary-key metadata for '\(table)'"
        case .invalidModelSQL: "PEARFY_SCHEMA_017: schema model contains empty or NUL-bearing SQL"
        case .invalidConstraint(let table, let constraint): "PEARFY_SCHEMA_018: invalid constraint '\(constraint)' on '\(table)'"
        case .invalidRelationship(let table, let field, let reason): "PEARFY_SCHEMA_019: invalid relationship '\(table).\(field)': \(reason)"
        case .unsupportedRelationshipChange(let table, let constraint): "PEARFY_SCHEMA_020: changing existing relationship constraint '\(table).\(constraint)' requires an explicit migration"
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
        var addedForeignKeys: [(SchemaEntity, SchemaForeignKey)] = []

        for entity in desired.entities {
            guard let oldEntity = previousTables[entity.table] else {
                statements.append(try createTable(entity))
                newEntities.append(entity)
                continue
            }
            guard oldEntity.primaryKey == entity.primaryKey else {
                throw SchemaCompilerError.unsupportedPrimaryKeyChange(table: entity.table)
            }
            guard oldEntity.indexes == entity.indexes else {
                throw SchemaCompilerError.unsupportedIndexChange(table: entity.table)
            }
            try diffColumns(from: oldEntity, to: entity, statements: &statements, destructive: &destructive)
            let oldForeignKeys = Dictionary(uniqueKeysWithValues: oldEntity.foreignKeys.map { ($0.name, $0) })
            let desiredForeignKeys = Dictionary(uniqueKeysWithValues: entity.foreignKeys.map { ($0.name, $0) })
            for (name, oldForeignKey) in oldForeignKeys where desiredForeignKeys[name] != oldForeignKey {
                throw SchemaCompilerError.unsupportedRelationshipChange(table: entity.table, constraint: name)
            }
            for foreignKey in entity.foreignKeys where oldForeignKeys[foreignKey.name] == nil {
                addedForeignKeys.append((entity, foreignKey))
            }
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
        for (entity, foreignKey) in addedForeignKeys.sorted(by: { ($0.0.table, $0.1.name) < ($1.0.table, $1.1.name) }) {
            statements += try createForeignKeys(SchemaEntity(
                table: entity.table,
                columns: entity.columns,
                foreignKeys: [foreignKey]
            ))
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

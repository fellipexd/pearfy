import Foundation
import Crypto
import PearfyData
import PearfyPopulateCore

public struct PopulateTableSize: Codable, Equatable, Sendable {
    public let rowCount: Int64
    public let heapBytes: Int64
    public let tableBytes: Int64
    public let indexBytes: Int64
    public let totalBytes: Int64

    public init(rowCount: Int64, heapBytes: Int64, tableBytes: Int64, indexBytes: Int64, totalBytes: Int64) {
        self.rowCount = rowCount
        self.heapBytes = heapBytes
        self.tableBytes = tableBytes
        self.indexBytes = indexBytes
        self.totalBytes = totalBytes
    }

    public func bytes(for mode: PopulateSizeMode) -> Int64 {
        switch mode {
        case .total: totalBytes
        case .table: tableBytes
        case .heap: heapBytes
        }
    }
}

public struct PopulateColumnProfile: Codable, Equatable, Sendable {
    public let column: String
    public let nullCount: Int64
    public let distinctCount: Int64
    public let averageLength: Double?

    public init(column: String, nullCount: Int64, distinctCount: Int64, averageLength: Double?) {
        self.column = column
        self.nullCount = nullCount
        self.distinctCount = distinctCount
        self.averageLength = averageLength
    }
}

public struct PopulateShapeProfile: Codable, Equatable, Sendable {
    public let table: String
    public let rowCount: Int64
    public let columns: [PopulateColumnProfile]
    public let containsRawValues: Bool

    public init(table: String, rowCount: Int64, columns: [PopulateColumnProfile], containsRawValues: Bool = false) {
        self.table = table
        self.rowCount = rowCount
        self.columns = columns
        self.containsRawValues = containsRawValues
    }
}

public enum PostgresPopulateError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidSnapshot
    case migrationJournalUnavailable
    case unsafeEnvironment(String)
    case unsafeTarget(String)
    case unsupportedConstraint(String)
    case missingPrimaryKey(String)
    case missingParentRows(String)
    case invalidParentRows(String)
    case unsupportedType(String)
    case unsupportedTypeCast(String)
    case invalidSizeResult

    public var description: String {
        switch self {
        case .invalidSnapshot: "PEARFY_POPULATE_PG_001: PostgreSQL schema introspection returned an invalid snapshot"
        case .migrationJournalUnavailable: "PEARFY_POPULATE_PG_002: applied migrations could not be read from pearfy_schema_migrations"
        case .unsafeEnvironment(let target): "PEARFY_POPULATE_PG_003: refusing to write to a production-like database target: \(target)"
        case .unsafeTarget(let target): "PEARFY_POPULATE_PG_004: refusing to populate protected or side-effecting table \(target)"
        case .unsupportedConstraint(let detail): "PEARFY_POPULATE_PG_005: cannot generate data safely for constraint \(detail)"
        case .missingPrimaryKey(let table): "PEARFY_POPULATE_PG_006: idempotent population requires a supported single-column primary key on \(table)"
        case .missingParentRows(let foreignKey): "PEARFY_POPULATE_PG_007: no eligible existing parent rows for required foreign key \(foreignKey)"
        case .invalidParentRows(let foreignKey): "PEARFY_POPULATE_PG_008: cannot decode eligible parent references for \(foreignKey)"
        case .unsupportedType(let column): "PEARFY_POPULATE_PG_009: unsupported PostgreSQL value conversion for \(column)"
        case .unsupportedTypeCast(let type): "PEARFY_POPULATE_PG_010: refusing an unsafe or unsupported PostgreSQL type cast for \(type)"
        case .invalidSizeResult: "PEARFY_POPULATE_PG_011: PostgreSQL returned invalid row-count or relation-size metrics"
        }
    }
}

/// PostgreSQL-only introspection and batched executor. SQL values are never
/// logged or returned by the schema/profile APIs.
public struct PearfyPostgresPopulateAdapter: Sendable {
    private let database: any SQLDatabase
    private let snapshot: PopulateSchemaSnapshot

    public init(database: any SQLDatabase, snapshot: PopulateSchemaSnapshot) {
        self.database = database
        self.snapshot = snapshot
    }

    public static func inspect(database: any SQLDatabase) async throws -> PopulateSchemaSnapshot {
        let json = try await database.queryStrings(SQLQuery(unsafeSQL: snapshotSQL), column: "snapshot")
        guard let encoded = json.first, let data = encoded.data(using: .utf8) else {
            throw PostgresPopulateError.invalidSnapshot
        }
        var snapshot: PopulateSchemaSnapshot
        do {
            snapshot = try JSONDecoder().decode(PopulateSchemaSnapshot.self, from: data)
        } catch {
            throw PostgresPopulateError.invalidSnapshot
        }

        let journalExists = try await database.queryStrings(
            SQLQuery(unsafeSQL: "SELECT (to_regclass('pearfy_schema_migrations') IS NOT NULL)::text AS present"),
            column: "present"
        ).first == "true"
        if journalExists {
            let migrationJSON = try await database.queryStrings(SQLQuery(unsafeSQL: """
                SELECT COALESCE(
                    jsonb_agg(jsonb_build_object(
                        'id', to_jsonb(migration_row)->>'id',
                        'checksum', to_jsonb(migration_row)->>'checksum'
                    ) ORDER BY to_jsonb(migration_row)->>'id'),
                    '[]'::jsonb
                )::text AS migrations
                FROM pearfy_schema_migrations AS migration_row
                """), column: "migrations")
            guard let migrationData = migrationJSON.first?.data(using: .utf8),
                  let migrations = try? JSONDecoder().decode([PopulateAppliedMigration].self, from: migrationData) else {
                throw PostgresPopulateError.migrationJournalUnavailable
            }
            snapshot = PopulateSchemaSnapshot(
                databaseName: snapshot.databaseName,
                serverAddress: snapshot.serverAddress,
                serverPort: snapshot.serverPort,
                tables: snapshot.tables,
                appliedMigrations: migrations
            )
        }
        return snapshot
    }

    public func size(of table: PopulateTable) async throws -> PopulateTableSize {
        let relation = try qualified(table.schema, table.name)
        let query = SQLQuery(unsafeSQL: """
            SELECT json_build_object(
                'rowCount', (SELECT count(*) FROM \(relation)),
                'heapBytes', pg_relation_size('\(table.schema).\(table.name)'::regclass),
                'tableBytes', pg_table_size('\(table.schema).\(table.name)'::regclass),
                'indexBytes', pg_indexes_size('\(table.schema).\(table.name)'::regclass),
                'totalBytes', pg_total_relation_size('\(table.schema).\(table.name)'::regclass)
            )::text AS size
            """)
        guard let value = try await database.queryStrings(query, column: "size").first,
              let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SizeDocument.self, from: data) else {
            throw PostgresPopulateError.invalidSizeResult
        }
        return PopulateTableSize(
            rowCount: decoded.rowCount,
            heapBytes: decoded.heapBytes,
            tableBytes: decoded.tableBytes,
            indexBytes: decoded.indexBytes,
            totalBytes: decoded.totalBytes
        )
    }

    /// Returns only aggregate statistics. No row, key, text sample, or raw
    /// category value leaves the adapter.
    public func profile(_ table: PopulateTable) async throws -> PopulateShapeProfile {
        let relation = try qualified(table.schema, table.name)
        return try await database.withTransaction { transaction in
            try await transaction.execute(SQLQuery(unsafeSQL: "SET TRANSACTION READ ONLY"))
            let total = try await transaction.queryStrings(
                SQLQuery(unsafeSQL: "SELECT count(*)::text AS row_count FROM \(relation)"),
                column: "row_count"
            ).first.flatMap(Int64.init) ?? 0
            var profiles: [PopulateColumnProfile] = []
            for column in table.columns {
                let identifier = try SQLIdentifier(column.name)
                let textMeasure = Self.isTextType(column.sqlType)
                    ? "avg(char_length(\(identifier)::text))"
                    : "NULL::double precision"
                let query = SQLQuery(unsafeSQL: """
                    SELECT json_build_object(
                        'nullCount', count(*) FILTER (WHERE \(identifier) IS NULL),
                        'distinctCount', count(DISTINCT \(identifier)),
                        'averageLength', \(textMeasure)
                    )::text AS profile
                    FROM \(relation)
                    """)
                guard let json = try await transaction.queryStrings(query, column: "profile").first,
                      let data = json.data(using: .utf8),
                      let document = try? JSONDecoder().decode(ColumnProfileDocument.self, from: data) else {
                    throw PostgresPopulateError.invalidSnapshot
                }
                profiles.append(PopulateColumnProfile(
                    column: column.name,
                    nullCount: document.nullCount,
                    distinctCount: document.distinctCount,
                    averageLength: document.averageLength
                ))
            }
            return PopulateShapeProfile(table: table.qualifiedName, rowCount: total, columns: profiles)
        }
    }

    public func integerUniqueBases(for table: PopulateTable) async throws -> [String: Int64] {
        let uniqueNames = Set(table.primaryKey + table.uniqueConstraints.filter { !$0.isPartial && !$0.hasExpressions }.flatMap(\.columns))
        var values: [String: Int64] = [:]
        for name in uniqueNames {
            guard let column = table.column(named: name) else { continue }
            let type = column.sqlType.lowercased()
            let integerType = type.contains("int") || type.contains("serial")
            let numericType = type.contains("numeric") || type.contains("decimal")
            guard integerType || numericType else { continue }
            let relation = try qualified(table.schema, table.name)
            let identifier = try SQLIdentifier(name)
            let maximum = numericType ? "CEIL(COALESCE(MAX(\(identifier)), 0))" : "COALESCE(MAX(\(identifier)), 0)"
            let query = SQLQuery(unsafeSQL: "SELECT (\(maximum))::text AS maximum FROM \(relation)")
            guard let text = try await database.queryStrings(query, column: "maximum").first,
                  let maximum = Int64(text) else { throw PostgresPopulateError.invalidSizeResult }
            let (base, overflow) = maximum.addingReportingOverflow(1)
            guard !overflow else { throw PostgresPopulateError.invalidSizeResult }
            values[name] = base
            values["\(table.qualifiedName).\(name)"] = base
        }
        return values
    }

    public func validateWritable(_ table: PopulateTable, plannedRows: Int) throws {
        try Self.validateWritable(table, plannedRows: plannedRows)
    }

    public static func validateWritable(_ table: PopulateTable, plannedRows: Int) throws {
        guard !table.rowLevelSecurity,
              !table.isPartitioned,
              table.triggers.isEmpty else {
            throw PostgresPopulateError.unsafeTarget(table.qualifiedName)
        }
        guard table.primaryKey.count == 1,
              let primaryKey = table.column(named: table.primaryKey[0]),
              !primaryKey.identity,
              !primaryKey.generated,
              !primaryKey.hasDefault,
              isSupportedPrimaryKey(primaryKey) else {
            throw PostgresPopulateError.missingPrimaryKey(table.qualifiedName)
        }
        for constraint in table.uniqueConstraints {
            guard !constraint.isPartial, !constraint.hasExpressions, !constraint.columns.isEmpty else {
                throw PostgresPopulateError.unsupportedConstraint(constraint.name)
            }
            for columnName in constraint.columns {
                guard let column = table.column(named: columnName) else { throw PostgresPopulateError.unsupportedConstraint(constraint.name) }
                guard PopulateValueGenerator.supports(column) else {
                    throw PostgresPopulateError.unsupportedConstraint("unsupported unique type \(constraint.name).\(columnName)")
                }
                if table.foreignKeys.contains(where: { !$0.columns.filter(constraint.columns.contains).isEmpty }) {
                    throw PostgresPopulateError.unsupportedConstraint("unique foreign-key overlap \(constraint.name)")
                }
                if column.sqlType.lowercased().contains("bool") {
                    throw PostgresPopulateError.unsupportedConstraint("boolean unique key \(constraint.name)")
                }
                if !column.enumValues.isEmpty {
                    throw PostgresPopulateError.unsupportedConstraint("unique enum key \(constraint.name)")
                }
                if column.sqlType.lowercased().contains("timestamp")
                    || column.sqlType.lowercased().contains("time")
                    || column.sqlType.lowercased() == "date" {
                    throw PostgresPopulateError.unsupportedConstraint("unique temporal key \(constraint.name)")
                }
                if isTextType(column.sqlType),
                   let maximumLength = column.maximumLength,
                   maximumLength < 10 + String(max(0, plannedRows - 1), radix: 36).count {
                    throw PostgresPopulateError.unsupportedConstraint("unique text column too short \(constraint.name).\(columnName)")
                }
            }
        }
        for column in table.columns where !column.generated && !column.identity && !column.hasDefault
            && !table.foreignKeys.contains(where: { $0.columns.contains(column.name) }) {
            guard PopulateValueGenerator.supports(column) else {
                throw PostgresPopulateError.unsupportedConstraint("unsupported generated type \(table.qualifiedName).\(column.name)")
            }
        }
        for column in table.columns where !column.generated && !column.identity && !column.hasDefault {
            _ = try valueCast(for: column)
        }
        for check in table.checks where !PopulateValueGenerator.supports(check, in: table) {
            throw PostgresPopulateError.unsupportedConstraint(check.name)
        }
    }

    public func verify(_ plan: PopulatePlan) async throws -> PopulateVerification {
        let table = try snapshot.table(named: plan.table)
        let metrics = try await size(of: table)
        return PopulateVerification(
            table: table.qualifiedName,
            rowCount: metrics.rowCount,
            sizeBytes: metrics.bytes(for: plan.sizeMode ?? .total),
            targetSizeBytes: plan.targetSizeBytes,
            sizeReached: plan.targetSizeBytes.map { metrics.bytes(for: plan.sizeMode ?? .total) >= $0 } ?? true,
            schemaFingerprint: try snapshot.fingerprint()
        )
    }

    public func insertRows(plan: PopulatePlan, ordinals: Range<Int>) async throws -> PopulateBatchResult {
        let table = try snapshot.table(named: plan.table)
        try validateWritable(table, plannedRows: ordinals.count)
        let primaryKeyName = table.primaryKey[0]
        guard table.column(named: primaryKeyName) != nil else {
            throw PostgresPopulateError.missingPrimaryKey(table.qualifiedName)
        }
        let candidates = try await loadForeignKeyCandidates(for: table)
        let inserted = try await database.withMigrationLock(key: "pearfy-populate:\(plan.id)") { transaction in
            var inserted = 0
            for ordinal in ordinals {
                var values: [String: SQLValue] = [:]
                let foreignValues = try self.foreignKeyValues(
                    for: table,
                    candidates: candidates,
                    plan: plan,
                    ordinal: ordinal
                )
                for column in table.columns where !column.generated && !column.identity {
                    if let foreignValue = foreignValues[column.name] {
                        values[column.name] = foreignValue
                    } else if column.hasDefault && !table.primaryKey.contains(column.name) {
                        continue
                    } else {
                        let unique = table.primaryKey.contains(column.name)
                            || table.uniqueConstraints.contains { $0.columns.contains(column.name) }
                        values[column.name] = try PopulateValueGenerator.value(
                            for: column,
                            in: table,
                            rowOrdinal: ordinal,
                            plan: plan,
                            forceUnique: unique
                        )
                    }
                }

                let ordered = values.keys.sorted()
                guard !ordered.isEmpty else { throw PostgresPopulateError.missingPrimaryKey(table.qualifiedName) }
                let relation = try self.qualified(table.schema, table.name)
                let columns = try ordered.map { try SQLIdentifier($0).description }.joined(separator: ", ")
                let placeholders = try ordered.enumerated().map { index, name in
                    guard let column = table.column(named: name) else {
                        throw PostgresPopulateError.unsupportedConstraint("missing column \(table.qualifiedName).\(name)")
                    }
                    let cast = try Self.valueCast(for: column)
                    return "$\(index + 1)\(cast ?? "")"
                }.joined(separator: ", ")
                let keyIdentifier = try SQLIdentifier(primaryKeyName)
                let statement = "INSERT INTO \(relation) (\(columns)) VALUES (\(placeholders)) ON CONFLICT (\(keyIdentifier)) DO NOTHING RETURNING \(keyIdentifier)::text AS inserted_key"
                let query = SQLQuery(unsafeSQL: statement, parameters: ordered.map { values[$0] ?? .null })
                let returned = try await transaction.queryStrings(query, column: "inserted_key")
                if !returned.isEmpty {
                    inserted += 1
                } else if let primaryKeyValue = values[primaryKeyName] {
                    // Recover an acknowledgement after a process crash between
                    // database commit and local checkpoint write.
                    let existing = try await transaction.queryStrings(SQLQuery(
                        unsafeSQL: "SELECT \(keyIdentifier)::text AS existing_key FROM \(relation) WHERE \(keyIdentifier) = $1",
                        parameters: [primaryKeyValue]
                    ), column: "existing_key")
                    if !existing.isEmpty { inserted += 1 }
                }
            }
            return inserted
        }

        let sizeMode = plan.sizeMode ?? .total
        let measuredSize = try await size(of: table).bytes(for: sizeMode)
        return PopulateBatchResult(insertedRows: inserted, measuredSizeBytes: measuredSize)
    }

    private struct SizeDocument: Decodable {
        let rowCount: Int64
        let heapBytes: Int64
        let tableBytes: Int64
        let indexBytes: Int64
        let totalBytes: Int64
    }

    private struct ColumnProfileDocument: Decodable {
        let nullCount: Int64
        let distinctCount: Int64
        let averageLength: Double?
    }

    private struct CandidateKey: Hashable {
        let schema: String
        let table: String
        let columns: [String]
    }

    private func loadForeignKeyCandidates(for table: PopulateTable) async throws -> [CandidateKey: [[String]]] {
        var result: [CandidateKey: [[String]]] = [:]
        for foreignKey in table.foreignKeys {
            let key = CandidateKey(
                schema: foreignKey.referencedSchema,
                table: foreignKey.referencedTable,
                columns: foreignKey.referencedColumns
            )
            if result[key] != nil { continue }
            let parent = try snapshot.table(named: "\(key.schema).\(key.table)")
            guard key.columns.count == foreignKey.columns.count,
                  key.columns.allSatisfy({ parent.column(named: $0) != nil }) else {
                throw PostgresPopulateError.invalidParentRows(foreignKey.name)
            }
            let relation = try qualified(key.schema, key.table)
            let identifiers = try key.columns.map { try SQLIdentifier($0).description }
            let projection = identifiers.map { "\($0)::text" }.joined(separator: ", ")
            let order = identifiers.joined(separator: ", ")
            let arrays = identifiers.map { "\($0)::text" }.joined(separator: ", ")
            let query = SQLQuery(unsafeSQL: """
                SELECT COALESCE(json_agg(json_build_array(\(arrays))), '[]'::json)::text AS values
                FROM (SELECT \(projection) FROM \(relation) ORDER BY \(order) LIMIT 10000) AS eligible
                """)
            guard let json = try await database.queryStrings(query, column: "values").first,
                  let data = json.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else {
                throw PostgresPopulateError.invalidParentRows(foreignKey.name)
            }
            let rows = decoded.map { row in row.map { value in value as? String ?? "" } }
            result[key] = rows
        }
        return result
    }

    private func foreignKeyValues(
        for table: PopulateTable,
        candidates: [CandidateKey: [[String]]],
        plan: PopulatePlan,
        ordinal: Int
    ) throws -> [String: SQLValue] {
        var values: [String: SQLValue] = [:]
        for foreignKey in table.foreignKeys {
            let key = CandidateKey(
                schema: foreignKey.referencedSchema,
                table: foreignKey.referencedTable,
                columns: foreignKey.referencedColumns
            )
            guard let rows = candidates[key] else { throw PostgresPopulateError.invalidParentRows(foreignKey.name) }
            if rows.isEmpty {
                let columns = foreignKey.columns.compactMap { table.column(named: $0) }
                guard columns.count == foreignKey.columns.count, columns.allSatisfy(\.nullable) else {
                    throw PostgresPopulateError.missingParentRows(foreignKey.name)
                }
                for name in foreignKey.columns { values[name] = .null }
                continue
            }
            let digest = SHA256.hash(data: Data("\(plan.seed)|\(plan.id)|\(foreignKey.name)|\(ordinal)".utf8))
            let number = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let parentRow = rows[Int(number % UInt64(rows.count))]
            guard parentRow.count == foreignKey.columns.count else { throw PostgresPopulateError.invalidParentRows(foreignKey.name) }
            let parent = try snapshot.table(named: "\(foreignKey.referencedSchema).\(foreignKey.referencedTable)")
            for (offset, childName) in foreignKey.columns.enumerated() {
                guard table.column(named: childName) != nil,
                      let parentColumn = parent.column(named: foreignKey.referencedColumns[offset]) else {
                    throw PostgresPopulateError.invalidParentRows(foreignKey.name)
                }
                values[childName] = try sqlValue(parentRow[offset], type: parentColumn.sqlType, path: "\(table.qualifiedName).\(childName)")
            }
        }
        return values
    }

    private func sqlValue(_ value: String, type: String, path: String) throws -> SQLValue {
        let normalized = type.lowercased()
        if normalized.contains("uuid") {
            guard let uuid = UUID(uuidString: value) else { throw PostgresPopulateError.unsupportedType(path) }
            return .uuid(uuid)
        }
        if normalized.contains("int") || normalized.contains("serial") {
            guard let number = Int64(value) else { throw PostgresPopulateError.unsupportedType(path) }
            return .integer(number)
        }
        if normalized.contains("numeric") || normalized.contains("decimal") || normalized.contains("real") || normalized.contains("double") {
            guard let number = Double(value) else { throw PostgresPopulateError.unsupportedType(path) }
            return .decimal(number)
        }
        if normalized == "boolean" || normalized == "bool" {
            guard let bool = Bool(value) else { throw PostgresPopulateError.unsupportedType(path) }
            return .boolean(bool)
        }
        return .text(value)
    }

    private static func isSupportedPrimaryKey(_ column: PopulateColumn) -> Bool {
        let type = column.sqlType.lowercased()
        if type.contains("uuid") || type.contains("int") || type.contains("serial") { return true }
        return isTextType(type)
            && PopulateValueGenerator.supports(column)
            && (column.maximumLength ?? 128) >= 32
    }

    private static func isTextType(_ type: String) -> Bool {
        let value = type.lowercased()
        return value.contains("char") || value.contains("text") || value.contains("citext") || value == "name"
    }

    private static func valueCast(for column: PopulateColumn) throws -> String? {
        let normalized = column.sqlType.lowercased()
        if !column.enumValues.isEmpty {
            let components = column.sqlType.split(separator: ".", omittingEmptySubsequences: false).map { part in
                String(part).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            guard !components.isEmpty,
                  components.allSatisfy({ (try? SQLIdentifier($0)) != nil }) else {
                throw PostgresPopulateError.unsupportedTypeCast(column.sqlType)
            }
            return "::" + (try components.map { try SQLIdentifier($0).description }).joined(separator: ".")
        }
        if (normalized.contains("timestamp") && normalized.contains("with time zone")) || normalized == "timestamptz" { return "::TIMESTAMPTZ" }
        if (normalized.contains("timestamp") && normalized.contains("without time zone")) || normalized == "timestamp" { return "::TIMESTAMP" }
        if normalized == "date" { return "::DATE" }
        if (normalized.contains("time") && normalized.contains("with time zone") && !normalized.contains("timestamp")) || normalized == "timetz" { return "::TIMETZ" }
        if (normalized.contains("time") && normalized.contains("without time zone") && !normalized.contains("timestamp")) || normalized == "time" { return "::TIME" }
        return nil
    }

    private func qualified(_ schema: String, _ table: String) throws -> String {
        "\(try SQLIdentifier(schema).description).\(try SQLIdentifier(table).description)"
    }

    private static let snapshotSQL = #"""
    SELECT jsonb_build_object(
        'databaseName', current_database(),
        'serverAddress', inet_server_addr()::text,
        'serverPort', inet_server_port(),
        'appliedMigrations', '[]'::jsonb,
        'tables', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'schema', namespace.nspname,
                'name', relation.relname,
                'columns', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                        'name', attribute.attname,
                        'sqlType', format_type(attribute.atttypid, attribute.atttypmod),
                        'nullable', NOT attribute.attnotnull,
                        'hasDefault', (default_value.oid IS NOT NULL),
                        'identity', (attribute.attidentity <> ''),
                        'generated', (attribute.attgenerated <> ''),
                        'maximumLength', CASE
                            WHEN type_info.typname IN ('varchar', 'bpchar') AND attribute.atttypmod > 4
                                THEN attribute.atttypmod - 4
                            ELSE NULL
                        END,
                        'enumValues', COALESCE((
                            SELECT jsonb_agg(enum_value.enumlabel ORDER BY enum_value.enumsortorder)
                            FROM pg_enum AS enum_value
                            WHERE enum_value.enumtypid = attribute.atttypid
                        ), '[]'::jsonb)
                    ) ORDER BY attribute.attnum)
                    FROM pg_attribute AS attribute
                    JOIN pg_type AS type_info ON type_info.oid = attribute.atttypid
                    LEFT JOIN pg_attrdef AS default_value
                        ON default_value.adrelid = attribute.attrelid AND default_value.adnum = attribute.attnum
                    WHERE attribute.attrelid = relation.oid
                      AND attribute.attnum > 0
                      AND NOT attribute.attisdropped
                ), '[]'::jsonb),
                'primaryKey', COALESCE((
                    SELECT jsonb_agg(attribute.attname ORDER BY key_column.ordinality)
                    FROM pg_constraint AS constraint_row
                    CROSS JOIN LATERAL unnest(constraint_row.conkey) WITH ORDINALITY AS key_column(attnum, ordinality)
                    JOIN pg_attribute AS attribute
                      ON attribute.attrelid = relation.oid AND attribute.attnum = key_column.attnum
                    WHERE constraint_row.conrelid = relation.oid AND constraint_row.contype = 'p'
                ), '[]'::jsonb),
                'uniqueConstraints', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                        'name', index_relation.relname,
                        'columns', COALESCE((
                            SELECT jsonb_agg(attribute.attname ORDER BY key_column.ordinality)
                            FROM unnest(index_row.indkey::smallint[]) WITH ORDINALITY AS key_column(attnum, ordinality)
                            JOIN pg_attribute AS attribute
                              ON attribute.attrelid = relation.oid AND attribute.attnum = key_column.attnum
                            WHERE key_column.attnum > 0
                        ), '[]'::jsonb),
                        'definition', pg_get_indexdef(index_row.indexrelid),
                        'isPartial', index_row.indpred IS NOT NULL,
                        'hasExpressions', index_row.indexprs IS NOT NULL
                    ) ORDER BY index_relation.relname)
                    FROM pg_index AS index_row
                    JOIN pg_class AS index_relation ON index_relation.oid = index_row.indexrelid
                    WHERE index_row.indrelid = relation.oid AND index_row.indisunique
                ), '[]'::jsonb),
                'foreignKeys', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                        'name', constraint_row.conname,
                        'columns', (SELECT jsonb_agg(source_attribute.attname ORDER BY source_key.ordinality)
                            FROM unnest(constraint_row.conkey) WITH ORDINALITY AS source_key(attnum, ordinality)
                            JOIN pg_attribute AS source_attribute
                              ON source_attribute.attrelid = relation.oid AND source_attribute.attnum = source_key.attnum),
                        'referencedSchema', parent_namespace.nspname,
                        'referencedTable', parent_relation.relname,
                        'referencedColumns', (SELECT jsonb_agg(parent_attribute.attname ORDER BY parent_key.ordinality)
                            FROM unnest(constraint_row.confkey) WITH ORDINALITY AS parent_key(attnum, ordinality)
                            JOIN pg_attribute AS parent_attribute
                              ON parent_attribute.attrelid = parent_relation.oid AND parent_attribute.attnum = parent_key.attnum),
                        'isDeferrable', constraint_row.condeferrable
                    ) ORDER BY constraint_row.conname)
                    FROM pg_constraint AS constraint_row
                    JOIN pg_class AS parent_relation ON parent_relation.oid = constraint_row.confrelid
                    JOIN pg_namespace AS parent_namespace ON parent_namespace.oid = parent_relation.relnamespace
                    WHERE constraint_row.conrelid = relation.oid AND constraint_row.contype = 'f'
                ), '[]'::jsonb),
                'checks', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object('name', constraint_row.conname, 'expression', pg_get_constraintdef(constraint_row.oid)) ORDER BY constraint_row.conname)
                    FROM pg_constraint AS constraint_row
                    WHERE constraint_row.conrelid = relation.oid AND constraint_row.contype = 'c'
                ), '[]'::jsonb),
                'triggers', COALESCE((
                    SELECT jsonb_agg(trigger_row.tgname ORDER BY trigger_row.tgname)
                    FROM pg_trigger AS trigger_row
                    WHERE trigger_row.tgrelid = relation.oid AND NOT trigger_row.tgisinternal
                ), '[]'::jsonb),
                'rowLevelSecurity', relation.relrowsecurity,
                'isPartitioned', relation.relkind = 'p'
            ) ORDER BY namespace.nspname, relation.relname)
            FROM pg_class AS relation
            JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
            WHERE relation.relkind IN ('r', 'p')
              AND namespace.nspname NOT IN ('pg_catalog', 'information_schema')
              AND namespace.nspname NOT LIKE 'pg_toast%'
        ), '[]'::jsonb)
    )::text AS snapshot
    """#
}

public struct PopulateVerification: Codable, Equatable, Sendable {
    public let table: String
    public let rowCount: Int64
    public let sizeBytes: Int64
    public let targetSizeBytes: Int64?
    public let sizeReached: Bool
    public let schemaFingerprint: String

    public init(
        table: String,
        rowCount: Int64,
        sizeBytes: Int64,
        targetSizeBytes: Int64?,
        sizeReached: Bool,
        schemaFingerprint: String
    ) {
        self.table = table
        self.rowCount = rowCount
        self.sizeBytes = sizeBytes
        self.targetSizeBytes = targetSizeBytes
        self.sizeReached = sizeReached
        self.schemaFingerprint = schemaFingerprint
    }
}

extension PearfyPostgresPopulateAdapter: PopulateExecutionStore {}

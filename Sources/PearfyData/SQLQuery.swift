import Foundation
import Crypto

public enum SQLValue: Sendable, Equatable, Codable {
    case null
    case text(String)
    case integer(Int64)
    case decimal(Double)
    case boolean(Bool)
    case uuid(UUID)
    case bytes(Data)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case null
        case text
        case integer
        case decimal
        case boolean
        case uuid
        case bytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .null: self = .null
        case .text: self = .text(try container.decode(String.self, forKey: .value))
        case .integer: self = .integer(try container.decode(Int64.self, forKey: .value))
        case .decimal: self = .decimal(try container.decode(Double.self, forKey: .value))
        case .boolean: self = .boolean(try container.decode(Bool.self, forKey: .value))
        case .uuid: self = .uuid(try container.decode(UUID.self, forKey: .value))
        case .bytes: self = .bytes(try container.decode(Data.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode(Kind.null, forKey: .kind)
        case .text(let value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .integer(let value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .decimal(let value):
            try container.encode(Kind.decimal, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .boolean(let value):
            try container.encode(Kind.boolean, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .uuid(let value):
            try container.encode(Kind.uuid, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .bytes(let value):
            try container.encode(Kind.bytes, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

public enum SQLQueryError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidIdentifier(String)
    case emptyMutation(String)
    case duplicateMigration(String)
    case missingRollback(String)
    case missingColumn(String)
    case invalidMigrationID(String)
    case migrationChecksumMismatch(id: String, expected: String, recorded: String)
    case migrationNotApplied(String)

    public var description: String {
        switch self {
        case .invalidIdentifier(let value): "PEARFY_DATA_001: invalid SQL identifier '\(value)'"
        case .emptyMutation(let operation): "PEARFY_DATA_002: refusing an unbounded \(operation)"
        case .duplicateMigration(let id): "PEARFY_DATA_003: duplicate migration id '\(id)'"
        case .missingRollback(let id): "PEARFY_DATA_004: migration '\(id)' has no rollback query"
        case .missingColumn(let name): "PEARFY_DATA_005: result row does not contain column '\(name)'"
        case .invalidMigrationID(let id): "PEARFY_DATA_006: invalid migration id '\(id)'"
        case .migrationChecksumMismatch(let id, let expected, let recorded):
            "PEARFY_DATA_007: migration '\(id)' checksum mismatch (expected \(expected), recorded \(recorded))"
        case .migrationNotApplied(let id): "PEARFY_DATA_008: migration '\(id)' is not applied"
        }
    }
}

public struct SQLIdentifier: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    private init(validated value: String) {
        rawValue = value
    }

    public static let migrationJournal = SQLIdentifier(validated: "pearfy_schema_migrations")

    public init(_ value: String) throws {
        guard let first = value.utf8.first,
              (first == 95 || (65...90).contains(first) || (97...122).contains(first)),
              value.utf8.allSatisfy({ byte in
                  byte == 95 || (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
              }) else {
            throw SQLQueryError.invalidIdentifier(value)
        }
        rawValue = value
    }

    public var description: String { "\"\(rawValue)\"" }
}

public enum SQLComparison: String, Sendable {
    case equal = "="
    case notEqual = "<>"
    case lessThan = "<"
    case lessThanOrEqual = "<="
    case greaterThan = ">"
    case greaterThanOrEqual = ">="
}

public struct SQLFilter: Sendable {
    public let column: SQLIdentifier
    public let comparison: SQLComparison
    public let value: SQLValue

    public init(_ column: SQLIdentifier, _ comparison: SQLComparison = .equal, _ value: SQLValue) {
        self.column = column
        self.comparison = comparison
        self.value = value
    }
}

/// A SQL statement with separately stored values. The raw initializer is
/// explicitly named unsafe; prefer the identifier-validated builders below.
public struct SQLQuery: Sendable {
    public let statement: String
    public let parameters: [SQLValue]

    public init(unsafeSQL statement: String, parameters: [SQLValue] = []) {
        self.statement = statement
        self.parameters = parameters
    }

    public static func select(
        _ columns: [SQLIdentifier],
        from table: SQLIdentifier,
        where filters: [SQLFilter] = [],
        limit: Int? = nil
    ) throws -> SQLQuery {
        let selection = columns.isEmpty ? "*" : columns.map(\.description).joined(separator: ", ")
        var parameters: [SQLValue] = []
        let predicates = try filters.map { try predicate($0, parameters: &parameters) }
        var statement = "SELECT \(selection) FROM \(table)"
        if !predicates.isEmpty { statement += " WHERE \(predicates.joined(separator: " AND "))" }
        if let limit {
            guard limit >= 0 else { throw SQLQueryError.emptyMutation("negative limit") }
            parameters.append(.integer(Int64(limit)))
            statement += " LIMIT $\(parameters.count)"
        }
        return SQLQuery(unsafeSQL: statement, parameters: parameters)
    }

    public static func insert(into table: SQLIdentifier, values: [SQLIdentifier: SQLValue]) throws -> SQLQuery {
        guard !values.isEmpty else { throw SQLQueryError.emptyMutation("INSERT") }
        let ordered = values.sorted { $0.key.rawValue < $1.key.rawValue }
        let columns = ordered.map { $0.key.description }.joined(separator: ", ")
        let placeholders = ordered.indices.map { "$\($0 + 1)" }.joined(separator: ", ")
        return SQLQuery(
            unsafeSQL: "INSERT INTO \(table) (\(columns)) VALUES (\(placeholders))",
            parameters: ordered.map(\.value)
        )
    }

    public static func update(
        _ table: SQLIdentifier,
        values: [SQLIdentifier: SQLValue],
        where filters: [SQLFilter]
    ) throws -> SQLQuery {
        guard !values.isEmpty else { throw SQLQueryError.emptyMutation("UPDATE") }
        guard !filters.isEmpty else { throw SQLQueryError.emptyMutation("unfiltered UPDATE") }
        let ordered = values.sorted { $0.key.rawValue < $1.key.rawValue }
        var parameters = ordered.map(\.value)
        let assignments = ordered.enumerated().map { index, item in
            "\(item.key) = $\(index + 1)"
        }.joined(separator: ", ")
        let predicates = try filters.map { try predicate($0, parameters: &parameters) }
        return SQLQuery(
            unsafeSQL: "UPDATE \(table) SET \(assignments) WHERE \(predicates.joined(separator: " AND "))",
            parameters: parameters
        )
    }

    public static func delete(from table: SQLIdentifier, where filters: [SQLFilter]) throws -> SQLQuery {
        guard !filters.isEmpty else { throw SQLQueryError.emptyMutation("unfiltered DELETE") }
        var parameters: [SQLValue] = []
        let predicates = try filters.map { try predicate($0, parameters: &parameters) }
        return SQLQuery(
            unsafeSQL: "DELETE FROM \(table) WHERE \(predicates.joined(separator: " AND "))",
            parameters: parameters
        )
    }

    private static func predicate(_ filter: SQLFilter, parameters: inout [SQLValue]) throws -> String {
        if case .null = filter.value {
            switch filter.comparison {
            case .equal: return "\(filter.column) IS NULL"
            case .notEqual: return "\(filter.column) IS NOT NULL"
            default: throw SQLQueryError.emptyMutation("comparison against NULL")
            }
        }
        parameters.append(filter.value)
        return "\(filter.column) \(filter.comparison.rawValue) $\(parameters.count)"
    }
}

public protocol SQLTransaction: Sendable {
    func execute(_ query: SQLQuery) async throws
    func queryStrings(_ query: SQLQuery, column: String) async throws -> [String]
}

public protocol SQLDatabase: Sendable {
    func execute(_ query: SQLQuery) async throws
    func queryStrings(_ query: SQLQuery, column: String) async throws -> [String]
    func withTransaction<Value: Sendable>(
        _ operation: @Sendable (any SQLTransaction) async throws -> Value
    ) async throws -> Value
    /// Runs an operation in a database transaction while holding the same
    /// durable, cross-process lock for every caller using `key`.
    func withMigrationLock<Value: Sendable>(
        key: String,
        _ operation: @Sendable (any SQLTransaction) async throws -> Value
    ) async throws -> Value
}

public struct SQLMigration: Sendable {
    public let id: String
    public let up: SQLQuery
    public let down: SQLQuery?

    public init(id: String, up: SQLQuery, down: SQLQuery? = nil) {
        self.id = id
        self.up = up
        self.down = down
    }

    /// Stable SHA-256 of the immutable migration ID and its up/down statements.
    public var checksum: String {
        SQLMigrationChecksum.compute(id: id, up: up, down: down)
    }
}

public enum SQLMigrationPlanStatus: Codable, Equatable, Sendable {
    case pending
    case applied
    case legacyNeedsChecksum
    case checksumDrift(recorded: String)
}

public struct SQLMigrationPlanEntry: Codable, Equatable, Sendable {
    public let id: String
    public let checksum: String
    public let status: SQLMigrationPlanStatus

    public init(id: String, checksum: String, status: SQLMigrationPlanStatus) {
        self.id = id
        self.checksum = checksum
        self.status = status
    }
}

/// A point-in-time report for the declared migration IDs. Planning can create
/// or upgrade the bookkeeping journal, but never executes an application's
/// `up` or `down` SQL statements.
public struct SQLMigrationPlan: Codable, Equatable, Sendable {
    public let entries: [SQLMigrationPlanEntry]

    public init(entries: [SQLMigrationPlanEntry]) {
        self.entries = entries
    }

    public var pendingIDs: [String] {
        entries.filter { $0.status == .pending }.map(\.id)
    }

    public var legacyIDs: [String] {
        entries.filter { $0.status == .legacyNeedsChecksum }.map(\.id)
    }

    public var driftedIDs: [String] {
        entries.compactMap { entry in
            if case .checksumDrift = entry.status { return entry.id }
            return nil
        }
    }

    public var isUpToDate: Bool {
        entries.allSatisfy { $0.status == .applied }
    }
}

public struct SQLMigrationRunner: Sendable {
    public let journalTable: SQLIdentifier

    public init(journalTable: SQLIdentifier = .migrationJournal) {
        self.journalTable = journalTable
    }

    public func plan(_ migrations: [SQLMigration], on database: any SQLDatabase) async throws -> SQLMigrationPlan {
        let ordered = try Self.ordered(migrations)
        try await ensureJournal(on: database)

        let journal = journalTable.description
        var entries: [SQLMigrationPlanEntry] = []
        for migration in ordered {
            let status = try await database.withMigrationLock(key: lockKey(for: migration.id)) { transaction in
                let recorded = try await Self.recordedChecksum(
                    for: migration.id,
                    in: journal,
                    transaction: transaction
                )
                guard let recorded else { return SQLMigrationPlanStatus.pending }
                if recorded == Self.legacyChecksumMarker { return .legacyNeedsChecksum }
                guard recorded == migration.checksum else { return .checksumDrift(recorded: recorded) }
                return .applied
            }
            entries.append(SQLMigrationPlanEntry(
                id: migration.id,
                checksum: migration.checksum,
                status: status
            ))
        }
        return SQLMigrationPlan(entries: entries)
    }

    public func apply(_ migrations: [SQLMigration], to database: any SQLDatabase) async throws {
        let ordered = try Self.ordered(migrations)
        try await ensureJournal(on: database)

        let journal = journalTable.description
        for migration in ordered {
            try await database.withMigrationLock(key: lockKey(for: migration.id)) { transaction in
                let recorded = try await Self.recordedChecksum(
                    for: migration.id,
                    in: journal,
                    transaction: transaction
                )
                if let recorded {
                    if recorded == Self.legacyChecksumMarker {
                        try await transaction.execute(SQLQuery(
                            unsafeSQL: "UPDATE \(journal) SET checksum = $2 WHERE id = $1 AND checksum IS NULL",
                            parameters: [.text(migration.id), .text(migration.checksum)]
                        ))
                    } else if recorded != migration.checksum {
                        throw SQLQueryError.migrationChecksumMismatch(
                            id: migration.id,
                            expected: migration.checksum,
                            recorded: recorded
                        )
                    }
                    return
                }

                try await transaction.execute(migration.up)
                try await transaction.execute(SQLQuery(
                    unsafeSQL: "INSERT INTO \(journal) (id, checksum) VALUES ($1, $2)",
                    parameters: [.text(migration.id), .text(migration.checksum)]
                ))
            }
        }
    }

    public func rollback(_ migration: SQLMigration, on database: any SQLDatabase) async throws {
        guard let down = migration.down else { throw SQLQueryError.missingRollback(migration.id) }
        _ = try Self.ordered([migration])
        try await ensureJournal(on: database)

        let journal = journalTable.description
        try await database.withMigrationLock(key: lockKey(for: migration.id)) { transaction in
            guard let recorded = try await Self.recordedChecksum(
                for: migration.id,
                in: journal,
                transaction: transaction
            ) else {
                throw SQLQueryError.migrationNotApplied(migration.id)
            }
            if recorded != Self.legacyChecksumMarker && recorded != migration.checksum {
                throw SQLQueryError.migrationChecksumMismatch(
                    id: migration.id,
                    expected: migration.checksum,
                    recorded: recorded
                )
            }
            if recorded == Self.legacyChecksumMarker {
                try await transaction.execute(SQLQuery(
                    unsafeSQL: "UPDATE \(journal) SET checksum = $2 WHERE id = $1 AND checksum IS NULL",
                    parameters: [.text(migration.id), .text(migration.checksum)]
                ))
            }
            try await transaction.execute(down)
            try await transaction.execute(SQLQuery(
                unsafeSQL: "DELETE FROM \(journal) WHERE id = $1",
                parameters: [.text(migration.id)]
            ))
        }
    }

    private static let legacyChecksumMarker = "<legacy-null>"

    private func ensureJournal(on database: any SQLDatabase) async throws {
        let journal = journalTable.description
        try await database.withMigrationLock(key: "\(journalTable.rawValue):bootstrap") { transaction in
            try await transaction.execute(SQLQuery(unsafeSQL: """
            CREATE TABLE IF NOT EXISTS \(journal) (
                id TEXT PRIMARY KEY,
                checksum TEXT,
                applied_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """))
            try await transaction.execute(SQLQuery(
                unsafeSQL: "ALTER TABLE \(journal) ADD COLUMN IF NOT EXISTS checksum TEXT"
            ))
            try await transaction.execute(SQLQuery(
                unsafeSQL: "ALTER TABLE \(journal) ADD COLUMN IF NOT EXISTS applied_at TIMESTAMPTZ"
            ))
            try await transaction.execute(SQLQuery(
                unsafeSQL: "UPDATE \(journal) SET applied_at = CURRENT_TIMESTAMP WHERE applied_at IS NULL"
            ))
            try await transaction.execute(SQLQuery(
                unsafeSQL: "ALTER TABLE \(journal) ALTER COLUMN applied_at SET DEFAULT CURRENT_TIMESTAMP"
            ))
            try await transaction.execute(SQLQuery(
                unsafeSQL: "ALTER TABLE \(journal) ALTER COLUMN applied_at SET NOT NULL"
            ))
        }
    }

    private func lockKey(for migrationID: String) -> String {
        "\(journalTable.rawValue):\(migrationID)"
    }

    private static func recordedChecksum(
        for migrationID: String,
        in journal: String,
        transaction: any SQLTransaction
    ) async throws -> String? {
        let values = try await transaction.queryStrings(SQLQuery(
            unsafeSQL: "SELECT COALESCE(checksum, '\(legacyChecksumMarker)')::TEXT AS checksum FROM \(journal) WHERE id = $1",
            parameters: [.text(migrationID)]
        ), column: "checksum")
        return values.first
    }

    static func ordered(_ migrations: [SQLMigration]) throws -> [SQLMigration] {
        var seen: Set<String> = []
        for migration in migrations {
            let bytes = Array(migration.id.utf8)
            guard !bytes.isEmpty,
                  bytes.count <= 128,
                  (48...57).contains(bytes[0]) || (97...122).contains(bytes[0]),
                  bytes.allSatisfy({
                      (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
                  }) else {
                throw SQLQueryError.invalidMigrationID(migration.id)
            }
            guard seen.insert(migration.id).inserted else {
                throw SQLQueryError.duplicateMigration(migration.id)
            }
        }
        return migrations.sorted(by: { $0.id < $1.id })
    }
}

private enum SQLMigrationChecksum {
    static func compute(id: String, up: SQLQuery, down: SQLQuery?) -> String {
        var data = Data()
        append("pearfy-sql-migration-checksum-v1", to: &data)
        append(id, to: &data)
        append(query: up, to: &data)
        if let down {
            append("down", to: &data)
            append(query: down, to: &data)
        } else {
            append("no-down", to: &data)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func append(query: SQLQuery, to data: inout Data) {
        append("statement", to: &data)
        append(query.statement, to: &data)
        append(String(query.parameters.count), to: &data)
        for parameter in query.parameters {
            switch parameter {
            case .null:
                append("null", to: &data)
            case .text(let value):
                append("text", to: &data)
                append(value, to: &data)
            case .integer(let value):
                append("integer", to: &data)
                append(String(value), to: &data)
            case .decimal(let value):
                append("decimal", to: &data)
                append(String(value.bitPattern, radix: 16), to: &data)
            case .boolean(let value):
                append("boolean", to: &data)
                append(value ? "true" : "false", to: &data)
            case .uuid(let value):
                append("uuid", to: &data)
                append(value.uuidString.lowercased(), to: &data)
            case .bytes(let value):
                append("bytes", to: &data)
                append(value.base64EncodedString(), to: &data)
            }
        }
    }

    private static func append(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }
}

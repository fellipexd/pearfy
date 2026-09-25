import Foundation

public enum SQLValue: Sendable, Equatable {
    case null
    case text(String)
    case integer(Int64)
    case decimal(Double)
    case boolean(Bool)
    case uuid(UUID)
    case bytes(Data)
}

public enum SQLQueryError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidIdentifier(String)
    case emptyMutation(String)
    case duplicateMigration(String)
    case missingRollback(String)
    case missingColumn(String)

    public var description: String {
        switch self {
        case .invalidIdentifier(let value): "PEARFY_DATA_001: invalid SQL identifier '\(value)'"
        case .emptyMutation(let operation): "PEARFY_DATA_002: refusing an unbounded \(operation)"
        case .duplicateMigration(let id): "PEARFY_DATA_003: duplicate migration id '\(id)'"
        case .missingRollback(let id): "PEARFY_DATA_004: migration '\(id)' has no rollback query"
        case .missingColumn(let name): "PEARFY_DATA_005: result row does not contain column '\(name)'"
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
}

public struct SQLMigrationRunner: Sendable {
    public let journalTable: SQLIdentifier

    public init(journalTable: SQLIdentifier = .migrationJournal) {
        self.journalTable = journalTable
    }

    public func apply(_ migrations: [SQLMigration], to database: any SQLDatabase) async throws {
        let journal = journalTable.description
        try await database.execute(SQLQuery(unsafeSQL: "CREATE TABLE IF NOT EXISTS \(journal) (id TEXT PRIMARY KEY)"))
        let applied = Set(try await database.queryStrings(
            SQLQuery(unsafeSQL: "SELECT id FROM \(journal) ORDER BY id"),
            column: "id"
        ))
        var seen: Set<String> = []
        for migration in migrations.sorted(by: { $0.id < $1.id }) {
            guard seen.insert(migration.id).inserted else {
                throw SQLQueryError.duplicateMigration(migration.id)
            }
            guard !applied.contains(migration.id) else { continue }
            try await database.withTransaction { transaction in
                try await transaction.execute(migration.up)
                try await transaction.execute(SQLQuery(
                    unsafeSQL: "INSERT INTO \(journal) (id) VALUES ($1)",
                    parameters: [.text(migration.id)]
                ))
            }
        }
    }

    public func rollback(_ migration: SQLMigration, on database: any SQLDatabase) async throws {
        guard let down = migration.down else { throw SQLQueryError.missingRollback(migration.id) }
        let journal = journalTable.description
        try await database.withTransaction { transaction in
            try await transaction.execute(down)
            try await transaction.execute(SQLQuery(
                unsafeSQL: "DELETE FROM \(journal) WHERE id = $1",
                parameters: [.text(migration.id)]
            ))
        }
    }
}

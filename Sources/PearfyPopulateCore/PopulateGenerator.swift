import Crypto
import Foundation
import PearfyData

public enum PopulateValueError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedType(table: String, column: String, sqlType: String)
    case unsupportedUniqueType(table: String, column: String, sqlType: String)
    case uniqueBaseMissing(table: String, column: String)
    case uniqueTextTooShort(table: String, column: String)
    case unsupportedCheck(table: String, column: String, expression: String)
    case invalidGeneratedValue(table: String, column: String)

    public var description: String {
        switch self {
        case .unsupportedType(let table, let column, let sqlType):
            "PEARFY_POPULATE_009: unsupported SQL type '\(sqlType)' on \(table).\(column)"
        case .unsupportedUniqueType(let table, let column, let sqlType):
            "PEARFY_POPULATE_010: unique values for SQL type '\(sqlType)' are not supported on \(table).\(column)"
        case .uniqueBaseMissing(let table, let column):
            "PEARFY_POPULATE_011: plan is missing a unique value base for \(table).\(column)"
        case .uniqueTextTooShort(let table, let column):
            "PEARFY_POPULATE_012: text column \(table).\(column) is too short for a collision-resistant synthetic namespace"
        case .unsupportedCheck(let table, let column, let expression):
            "PEARFY_POPULATE_013: check constraint cannot be safely generated for \(table).\(column): \(expression)"
        case .invalidGeneratedValue(let table, let column):
            "PEARFY_POPULATE_014: generated value violates the known constraints on \(table).\(column)"
        }
    }
}

/// Reproducible, privacy-safe scalar generation. It never samples a real row.
public enum PopulateValueGenerator {
    public static func supports(_ column: PopulateColumn) -> Bool {
        if !column.enumValues.isEmpty { return true }
        let type = column.sqlType.lowercased()
        return type.contains("uuid")
            || type.contains("int")
            || type.contains("serial")
            || type.contains("bool")
            || type.contains("numeric")
            || type.contains("decimal")
            || type.contains("real")
            || type.contains("double")
            || type == "money"
            || type.contains("timestamp")
            || type == "date"
            || type.contains("time without time zone")
            || type.contains("char")
            || type.contains("text")
            || type.contains("citext")
            || type.contains("name")
    }

    public static func supports(_ check: PopulateCheckConstraint, in table: PopulateTable) -> Bool {
        let referenced = table.columns.filter { references(check.expression, column: $0.name) }
        guard referenced.count == 1 else { return false }
        let column = referenced[0]
        let type = column.sqlType.lowercased()
        return (type.contains("int") || type.contains("serial"))
            && !bounds(in: check.expression, column: column.name).isEmpty
    }

    public static func value(
        for column: PopulateColumn,
        in table: PopulateTable,
        rowOrdinal: Int,
        plan: PopulatePlan,
        forceUnique: Bool = false
    ) throws -> SQLValue {
        guard rowOrdinal >= 0 else { throw PopulatePlanError.invalidPlan }
        if column.nullable && !forceUnique && randomWord(plan: plan, column: column.name, row: rowOrdinal) % 20 == 0 {
            return .null
        }
        let type = column.sqlType.lowercased()
        if !column.enumValues.isEmpty {
            if forceUnique {
                throw PopulateValueError.unsupportedUniqueType(table: table.qualifiedName, column: column.name, sqlType: column.sqlType)
            }
            let index = Int(randomWord(plan: plan, column: column.name, row: rowOrdinal) % UInt64(column.enumValues.count))
            return .text(column.enumValues[index])
        }
        if type.contains("uuid") { return .uuid(uuidV7(plan: plan, column: column.name, row: rowOrdinal)) }
        if type == "boolean" || type == "bool" {
            if forceUnique { throw PopulateValueError.unsupportedUniqueType(table: table.qualifiedName, column: column.name, sqlType: column.sqlType) }
            return .boolean(randomWord(plan: plan, column: column.name, row: rowOrdinal) & 1 == 1)
        }
        if type.contains("int") || type.contains("serial") {
            if forceUnique {
                guard let base = plan.integerUniqueBases["\(table.qualifiedName).\(column.name)"]
                        ?? plan.integerUniqueBases[column.name] else {
                    throw PopulateValueError.uniqueBaseMissing(table: table.qualifiedName, column: column.name)
                }
                let (value, overflow) = base.addingReportingOverflow(Int64(rowOrdinal))
                guard !overflow, satisfiesChecks(value, column: column.name, table: table) else {
                    throw PopulateValueError.invalidGeneratedValue(table: table.qualifiedName, column: column.name)
                }
                return .integer(value)
            }
            let candidate = Int64(randomWord(plan: plan, column: column.name, row: rowOrdinal) % 1_000_000)
            let adjusted = adjust(candidate, column: column.name, table: table)
            guard satisfiesChecks(adjusted, column: column.name, table: table) else {
                throw PopulateValueError.invalidGeneratedValue(table: table.qualifiedName, column: column.name)
            }
            return .integer(adjusted)
        }
        if type.contains("numeric") || type.contains("decimal") || type.contains("real") || type.contains("double") || type == "money" {
            if forceUnique {
                guard let base = plan.integerUniqueBases["\(table.qualifiedName).\(column.name)"]
                        ?? plan.integerUniqueBases[column.name] else {
                    throw PopulateValueError.uniqueBaseMissing(table: table.qualifiedName, column: column.name)
                }
                let (value, overflow) = base.addingReportingOverflow(Int64(rowOrdinal))
                guard !overflow else { throw PopulateValueError.invalidGeneratedValue(table: table.qualifiedName, column: column.name) }
                return .decimal(Double(value))
            }
            return .decimal(Double(randomWord(plan: plan, column: column.name, row: rowOrdinal) % 100_000) / 100)
        }
        if type.contains("bool") { return .boolean(randomWord(plan: plan, column: column.name, row: rowOrdinal) & 1 == 1) }
        if type.contains("timestamp") || type == "date" || type.contains("time without time zone") {
            if forceUnique {
                throw PopulateValueError.unsupportedUniqueType(table: table.qualifiedName, column: column.name, sqlType: column.sqlType)
            }
            let seconds = Int64(randomWord(plan: plan, column: column.name, row: rowOrdinal) % 1_700_000_000)
            let instant = Date(timeIntervalSince1970: TimeInterval(seconds))
            let formatter = ISO8601DateFormatter()
            if type == "date" {
                formatter.formatOptions = [.withFullDate]
            } else {
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            }
            return .text(formatter.string(from: instant))
        }
        if type.contains("char") || type.contains("text") || type.contains("citext") || type.contains("name") {
            if forceUnique {
                let digest = digestPrefix(plan: plan, column: column.name, row: rowOrdinal, count: 8)
                let suffix = "pf\(digest)\(String(rowOrdinal, radix: 36))"
                let maximum = column.maximumLength ?? 128
                guard maximum >= suffix.utf8.count else {
                    throw PopulateValueError.uniqueTextTooShort(table: table.qualifiedName, column: column.name)
                }
                return .text(String(suffix.prefix(maximum)))
            }
            let value = "synthetic-\(digestPrefix(plan: plan, column: column.name, row: rowOrdinal, count: 16))"
            let maximum = column.maximumLength ?? 128
            return .text(String(value.prefix(maximum)))
        }
        throw PopulateValueError.unsupportedType(table: table.qualifiedName, column: column.name, sqlType: column.sqlType)
    }

    public static func uuidV7(plan: PopulatePlan, column: String, row: Int) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let timestamp = min(UInt64(1_700_000_000_000 + max(0, row)), (UInt64(1) << 48) - 1)
        bytes[0] = UInt8((timestamp >> 40) & 0xff)
        bytes[1] = UInt8((timestamp >> 32) & 0xff)
        bytes[2] = UInt8((timestamp >> 24) & 0xff)
        bytes[3] = UInt8((timestamp >> 16) & 0xff)
        bytes[4] = UInt8((timestamp >> 8) & 0xff)
        bytes[5] = UInt8(timestamp & 0xff)
        let digest = Array(SHA256.hash(data: Data("\(plan.seed)|\(plan.id)|\(column)|\(row)".utf8)))
        for index in 6..<16 { bytes[index] = digest[index] }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func randomWord(plan: PopulatePlan, column: String, row: Int) -> UInt64 {
        let digest = SHA256.hash(data: Data("\(plan.seed)|\(plan.id)|\(column)|\(row)".utf8))
        return digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func digestPrefix(plan: PopulatePlan, column: String, row: Int, count: Int) -> String {
        SHA256.hash(data: Data("\(plan.seed)|\(plan.id)|\(column)|\(row)".utf8))
            .prefix(count)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func adjust(_ value: Int64, column: String, table: PopulateTable) -> Int64 {
        var candidate = value
        for check in table.checks where references(check.expression, column: column) {
            for (op, bound) in bounds(in: check.expression, column: column) {
                switch op {
                case ">=": candidate = max(candidate, bound)
                case ">": candidate = max(candidate, bound + 1)
                case "<=": candidate = min(candidate, bound)
                case "<": candidate = min(candidate, bound - 1)
                case "=": candidate = bound
                default: break
                }
            }
        }
        return candidate
    }

    private static func satisfiesChecks(_ value: Int64, column: String, table: PopulateTable) -> Bool {
        for check in table.checks where references(check.expression, column: column) {
            let supported = bounds(in: check.expression, column: column)
            if supported.isEmpty { return false }
            for (op, bound) in supported {
                switch op {
                case ">=": if value < bound { return false }
                case ">": if value <= bound { return false }
                case "<=": if value > bound { return false }
                case "<": if value >= bound { return false }
                case "=": if value != bound { return false }
                default: return false
                }
            }
        }
        return true
    }

    private static func references(_ expression: String, column: String) -> Bool {
        let escapedColumn = NSRegularExpression.escapedPattern(for: column)
        let pattern = "(?i)(?:\"?\\w+\"?\\.)?\"?\(escapedColumn)\"?"
        return expression.range(of: pattern, options: .regularExpression) != nil
    }

    private static func bounds(in expression: String, column: String) -> [(String, Int64)] {
        let escapedColumn = NSRegularExpression.escapedPattern(for: column)
        let pattern = "(?i)(?:\"?\\w+\"?\\.)?\"?\(escapedColumn)\"?\\s*(>=|<=|>|<|=)\\s*(-?\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(expression.startIndex..<expression.endIndex, in: expression)
        return regex.matches(in: expression, range: range).compactMap { match in
            guard let operatorRange = Range(match.range(at: 1), in: expression),
                  let valueRange = Range(match.range(at: 2), in: expression),
                  let value = Int64(expression[valueRange]) else { return nil }
            return (String(expression[operatorRange]), value)
        }
    }
}

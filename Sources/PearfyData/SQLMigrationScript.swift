import Foundation

public enum SQLMigrationScriptError: Error, Sendable, Equatable, CustomStringConvertible {
    case unterminatedString
    case unterminatedIdentifier
    case unterminatedBlockComment
    case unterminatedDollarQuote
    case parameterizedScriptHasMultipleStatements
    case tooManyStatements(Int)
    case scriptTooLarge(Int)

    public var description: String {
        switch self {
        case .unterminatedString: "PEARFY_DATA_015: migration SQL contains an unterminated string literal"
        case .unterminatedIdentifier: "PEARFY_DATA_016: migration SQL contains an unterminated quoted identifier"
        case .unterminatedBlockComment: "PEARFY_DATA_017: migration SQL contains an unterminated block comment"
        case .unterminatedDollarQuote: "PEARFY_DATA_018: migration SQL contains an unterminated dollar-quoted body"
        case .parameterizedScriptHasMultipleStatements:
            "PEARFY_DATA_019: bound SQL parameters can only be used with a single migration statement"
        case .tooManyStatements(_): "PEARFY_DATA_020: migration SQL contains too many statements"
        case .scriptTooLarge(_): "PEARFY_DATA_021: migration SQL script exceeds the 16 MiB limit"
        }
    }
}

/// Splits trusted, checked-in migration text without splitting quoted values,
/// identifiers, comments, or PostgreSQL dollar-quoted procedural bodies.
public enum SQLMigrationScript {
    public static let maximumStatements = 1_024
    public static let maximumScriptBytes = 16 * 1_024 * 1_024

    public static func statements(in query: SQLQuery) throws -> [SQLQuery] {
        guard query.statement.utf8.count <= maximumScriptBytes else {
            throw SQLMigrationScriptError.scriptTooLarge(query.statement.utf8.count)
        }
        let statements = try split(query.statement)
        guard query.parameters.isEmpty || statements.count <= 1 else {
            throw SQLMigrationScriptError.parameterizedScriptHasMultipleStatements
        }
        if statements.count == 1 {
            return [SQLQuery(unsafeSQL: statements[0], parameters: query.parameters)]
        }
        return statements.map { SQLQuery(unsafeSQL: $0) }
    }

    private enum State {
        case normal
        case singleQuoted(escapeBackslashes: Bool)
        case doubleQuoted
        case lineComment
        case blockComment(depth: Int)
        case dollarQuoted(String)
    }

    private static func split(_ sql: String) throws -> [String] {
        let bytes = Array(sql.utf8)
        var statements: [String] = []
        var statementStart = 0
        var index = 0
        var state = State.normal

        while index < bytes.count {
            switch state {
            case .normal:
                if bytes[index] == 39 {
                    state = .singleQuoted(escapeBackslashes: isEscapeStringPrefix(bytes, quoteIndex: index))
                    index += 1
                } else if bytes[index] == 34 {
                    state = .doubleQuoted
                    index += 1
                } else if bytes[index] == 45, nextByte(in: bytes, at: index) == 45 {
                    state = .lineComment
                    index += 2
                } else if bytes[index] == 47, nextByte(in: bytes, at: index) == 42 {
                    state = .blockComment(depth: 1)
                    index += 2
                } else if bytes[index] == 36, let delimiter = dollarDelimiter(in: bytes, at: index) {
                    state = .dollarQuoted(delimiter)
                    index += delimiter.utf8.count
                } else if bytes[index] == 59 {
                    appendStatement(bytes[statementStart..<index], to: &statements)
                    guard statements.count <= maximumStatements else {
                        throw SQLMigrationScriptError.tooManyStatements(statements.count)
                    }
                    statementStart = index + 1
                    index += 1
                } else {
                    index += 1
                }

            case .singleQuoted(let escapeBackslashes):
                if bytes[index] == 39 {
                    if nextByte(in: bytes, at: index) == 39 {
                        index += 2
                    } else {
                        state = .normal
                        index += 1
                    }
                } else if escapeBackslashes, bytes[index] == 92, index + 1 < bytes.count {
                    index += 2
                } else {
                    index += 1
                }

            case .doubleQuoted:
                if bytes[index] == 34 {
                    if nextByte(in: bytes, at: index) == 34 {
                        index += 2
                    } else {
                        state = .normal
                        index += 1
                    }
                } else {
                    index += 1
                }

            case .lineComment:
                if bytes[index] == 10 || bytes[index] == 13 { state = .normal }
                index += 1

            case .blockComment(let depth):
                if bytes[index] == 47, nextByte(in: bytes, at: index) == 42 {
                    state = .blockComment(depth: depth + 1)
                    index += 2
                } else if bytes[index] == 42, nextByte(in: bytes, at: index) == 47 {
                    state = depth == 1 ? .normal : .blockComment(depth: depth - 1)
                    index += 2
                } else {
                    index += 1
                }

            case .dollarQuoted(let delimiter):
                if matches(delimiter, in: bytes, at: index) {
                    state = .normal
                    index += delimiter.utf8.count
                } else {
                    index += 1
                }
            }
        }

        switch state {
        case .normal, .lineComment:
            break
        case .singleQuoted:
            throw SQLMigrationScriptError.unterminatedString
        case .doubleQuoted:
            throw SQLMigrationScriptError.unterminatedIdentifier
        case .blockComment:
            throw SQLMigrationScriptError.unterminatedBlockComment
        case .dollarQuoted:
            throw SQLMigrationScriptError.unterminatedDollarQuote
        }
        appendStatement(bytes[statementStart..<bytes.count], to: &statements)
        guard statements.count <= maximumStatements else {
            throw SQLMigrationScriptError.tooManyStatements(statements.count)
        }
        return statements
    }

    private static func appendStatement(_ bytes: ArraySlice<UInt8>, to statements: inout [String]) {
        let statement = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !statement.isEmpty { statements.append(statement) }
    }

    private static func nextByte(in bytes: [UInt8], at index: Int) -> UInt8? {
        guard index + 1 < bytes.count else { return nil }
        return bytes[index + 1]
    }

    private static func isEscapeStringPrefix(_ bytes: [UInt8], quoteIndex: Int) -> Bool {
        guard quoteIndex > 0,
              (bytes[quoteIndex - 1] == 69 || bytes[quoteIndex - 1] == 101) else { return false }
        if quoteIndex == 1 { return true }
        return !isIdentifierByte(bytes[quoteIndex - 2])
    }

    private static func dollarDelimiter(in bytes: [UInt8], at start: Int) -> String? {
        var end = start + 1
        while end < bytes.count, bytes[end] != 36 {
            guard isIdentifierByte(bytes[end]) else { return nil }
            end += 1
        }
        guard end < bytes.count else { return nil }
        if end > start + 1, !isIdentifierStart(bytes[start + 1]) { return nil }
        return String(decoding: bytes[start...end], as: UTF8.self)
    }

    private static func matches(_ delimiter: String, in bytes: [UInt8], at start: Int) -> Bool {
        let token = Array(delimiter.utf8)
        guard start + token.count <= bytes.count else { return false }
        return bytes[start..<(start + token.count)].elementsEqual(token)
    }

    private static func isIdentifierStart(_ byte: UInt8) -> Bool {
        byte == 95 || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        isIdentifierStart(byte) || (48...57).contains(byte)
    }
}

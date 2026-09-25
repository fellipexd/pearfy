import Foundation
import PearfyCore

public struct ValidationViolation: Codable, Sendable, Equatable {
    public let field: String
    public let rule: String
    public let message: String

    public init(field: String, rule: String, message: String) {
        self.field = field
        self.rule = rule
        self.message = message
    }
}

public struct ValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    public let violations: [ValidationViolation]

    public init(violations: [ValidationViolation]) {
        self.violations = violations
    }

    public var diagnostic: PearfyDiagnostic {
        PearfyDiagnostic(code: "PEARFY_VALIDATION_001", message: description)
    }

    public var description: String {
        "PEARFY_VALIDATION_001: validation failed for \(violations.count) field(s)"
    }
}

public protocol Validatable: Sendable {
    func validationViolations() -> [ValidationViolation]
}

public func validate(_ value: any Validatable) throws {
    let violations = value.validationViolations()
    guard violations.isEmpty else { throw ValidationError(violations: violations) }
}

/// Marks a controller parameter as a JSON request body that must validate before use.
@propertyWrapper
public struct Valid<Value: Validatable>: Sendable {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
}

public struct ValidationResult: Sendable, Equatable {
    public let violations: [ValidationViolation]
    public var isValid: Bool { violations.isEmpty }

    public init(violations: [ValidationViolation] = []) {
        self.violations = violations
    }

    public func throwIfInvalid() throws {
        guard isValid else { throw ValidationError(violations: violations) }
    }
}

public struct Validator<Value: Sendable>: Sendable {
    private let checks: [@Sendable (Value) -> [ValidationViolation]]

    public init() {
        checks = []
    }

    private init(checks: [@Sendable (Value) -> [ValidationViolation]]) {
        self.checks = checks
    }

    public func adding(_ check: @escaping @Sendable (Value) -> [ValidationViolation]) -> Validator<Value> {
        Validator(checks: checks + [check])
    }

    public func validate(_ value: Value) -> ValidationResult {
        ValidationResult(violations: checks.flatMap { $0(value) })
    }
}

public enum ValidationRules {
    public static func notBlank(field: String, value: String) -> [ValidationViolation] {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [ValidationViolation(field: field, rule: "notBlank", message: "must not be blank")]
            : []
    }

    public static func length(
        field: String,
        value: String,
        minimum: Int? = nil,
        maximum: Int? = nil
    ) -> [ValidationViolation] {
        let count = value.count
        if let minimum, count < minimum {
            return [ValidationViolation(field: field, rule: "minLength", message: "must contain at least \(minimum) characters")]
        }
        if let maximum, count > maximum {
            return [ValidationViolation(field: field, rule: "maxLength", message: "must contain at most \(maximum) characters")]
        }
        return []
    }

    public static func minimum<Value: Comparable & Sendable>(
        field: String,
        value: Value,
        minimum: Value
    ) -> [ValidationViolation] {
        value < minimum
            ? [ValidationViolation(field: field, rule: "minimum", message: "must be at least \(minimum)")]
            : []
    }

    public static func maximum<Value: Comparable & Sendable>(
        field: String,
        value: Value,
        maximum: Value
    ) -> [ValidationViolation] {
        value > maximum
            ? [ValidationViolation(field: field, rule: "maximum", message: "must be at most \(maximum)")]
            : []
    }

    public static func matches(field: String, value: String, pattern: String) -> [ValidationViolation] {
        guard let range = value.range(of: pattern, options: .regularExpression),
              range == value.startIndex..<value.endIndex else {
            return [ValidationViolation(field: field, rule: "pattern", message: "has an invalid format")]
        }
        return []
    }
}

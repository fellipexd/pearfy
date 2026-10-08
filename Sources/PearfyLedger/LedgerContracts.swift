import Foundation
import PearfyData

public enum LedgerError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidCurrency
    case invalidScale
    case invalidMoneyAmount
    case decimalPrecisionExceedsScale
    case arithmeticOverflow
    case invalidAccountIdentifier
    case invalidOperation
    case unbalanced(currency: String, scale: UInt8)
    case invalidScopeOrKey
    case invalidResourceKey
    case idempotencyConflict
    case invalidCanonicalParameters
    case corruptStoredOperation

    public var description: String {
        switch self {
        case .invalidCurrency: "PEARFY_LEDGER_001: currency must be three uppercase ASCII letters"
        case .invalidScale: "PEARFY_LEDGER_002: monetary scale must be between 0 and 9"
        case .invalidMoneyAmount: "PEARFY_LEDGER_003: invalid exact monetary amount"
        case .decimalPrecisionExceedsScale: "PEARFY_LEDGER_004: amount has more fractional digits than its declared scale"
        case .arithmeticOverflow: "PEARFY_LEDGER_005: exact monetary arithmetic overflow"
        case .invalidAccountIdentifier: "PEARFY_LEDGER_006: invalid account identifier"
        case .invalidOperation: "PEARFY_LEDGER_007: operation result or posting set is invalid"
        case .unbalanced(let currency, let scale): "PEARFY_LEDGER_008: postings are not balanced for \(currency) at scale \(scale)"
        case .invalidScopeOrKey: "PEARFY_LEDGER_009: idempotency scope or key is invalid"
        case .invalidResourceKey: "PEARFY_LEDGER_010: resource lock key is invalid"
        case .idempotencyConflict: "PEARFY_LEDGER_011: idempotency key was reused with different parameters"
        case .invalidCanonicalParameters: "PEARFY_LEDGER_012: canonical operation parameters exceed the supported size"
        case .corruptStoredOperation: "PEARFY_LEDGER_013: persisted operation result is invalid"
        }
    }
}

/// Exact base-10 money represented as signed minor units. The caller supplies
/// the currency and scale; Pearfy does not assume a currency registry.
public struct LedgerMoney: Codable, Hashable, Sendable, CustomStringConvertible {
    public let minorUnits: Int64
    public let currency: String
    public let scale: UInt8

    private enum CodingKeys: String, CodingKey { case minorUnits, currency, scale }

    public init(minorUnits: Int64, currency: String, scale: UInt8) throws {
        guard currency.utf8.count == 3,
              currency.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw LedgerError.invalidCurrency
        }
        guard scale <= 9 else { throw LedgerError.invalidScale }
        self.minorUnits = minorUnits
        self.currency = currency
        self.scale = scale
    }

    /// Parses a decimal string without floating point. Excess fractional digits
    /// are rejected; Pearfy never rounds an amount implicitly.
    public init(decimal: String, currency: String, scale: UInt8) throws {
        guard scale <= 9 else { throw LedgerError.invalidScale }
        guard currency.utf8.count == 3,
              currency.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw LedgerError.invalidCurrency
        }
        let bytes = Array(decimal.utf8)
        guard !bytes.isEmpty, bytes.count <= 64 else { throw LedgerError.invalidMoneyAmount }
        let negative = bytes[0] == 45
        let digits = negative ? Array(bytes.dropFirst()) : bytes
        guard !digits.isEmpty, digits[0] != 43 else { throw LedgerError.invalidMoneyAmount }

        var decimalPoint: Int?
        for (index, byte) in digits.enumerated() {
            if byte == 46, decimalPoint == nil {
                decimalPoint = index
            } else if !(48...57).contains(byte) {
                throw LedgerError.invalidMoneyAmount
            }
        }
        let integerEnd = decimalPoint ?? digits.count
        let fractionalStart = decimalPoint.map { $0 + 1 } ?? digits.count
        let fractionCount = digits.count - fractionalStart
        guard integerEnd > 0, (decimalPoint == nil || fractionCount > 0) else {
            throw LedgerError.invalidMoneyAmount
        }
        guard fractionCount <= Int(scale) else { throw LedgerError.decimalPrecisionExceedsScale }

        let factor = UInt64(pow10(Int(scale)))
        guard let whole = Self.parseDigits(digits[..<integerEnd]),
              let fraction = Self.parseDigits(digits[fractionalStart...]) else {
            throw LedgerError.invalidMoneyAmount
        }
        let (scaledWhole, wholeOverflow) = whole.multipliedReportingOverflow(by: factor)
        let fractionalFactor = UInt64(pow10(Int(scale) - fractionCount))
        let (scaledFraction, fractionOverflow) = fraction.multipliedReportingOverflow(by: fractionalFactor)
        let (magnitude, sumOverflow) = scaledWhole.addingReportingOverflow(scaledFraction)
        let maxMagnitude = negative ? UInt64(Int64.max) + 1 : UInt64(Int64.max)
        guard !wholeOverflow, !fractionOverflow, !sumOverflow, magnitude <= maxMagnitude else {
            throw LedgerError.arithmeticOverflow
        }
        let value: Int64
        if negative {
            value = magnitude == UInt64(Int64.max) + 1 ? Int64.min : -Int64(magnitude)
        } else {
            value = Int64(magnitude)
        }
        self.minorUnits = value
        self.currency = currency
        self.scale = scale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            minorUnits: container.decode(Int64.self, forKey: .minorUnits),
            currency: container.decode(String.self, forKey: .currency),
            scale: container.decode(UInt8.self, forKey: .scale)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(minorUnits, forKey: .minorUnits)
        try container.encode(currency, forKey: .currency)
        try container.encode(scale, forKey: .scale)
    }

    public var description: String {
        let factor = UInt64(pow10(Int(scale)))
        let magnitude = minorUnits.magnitude
        let whole = magnitude / factor
        let fraction = magnitude % factor
        let sign = minorUnits < 0 ? "-" : ""
        if scale == 0 { return "\(sign)\(whole) \(currency)" }
        let fractionText = String(fraction)
        let padded = String(repeating: "0", count: Int(scale) - fractionText.count) + fractionText
        return "\(sign)\(whole).\(padded) \(currency)"
    }

    public func adding(_ other: LedgerMoney) throws -> LedgerMoney {
        try requireCompatible(other)
        let (sum, overflow) = minorUnits.addingReportingOverflow(other.minorUnits)
        guard !overflow else { throw LedgerError.arithmeticOverflow }
        return try LedgerMoney(minorUnits: sum, currency: currency, scale: scale)
    }

    public func subtracting(_ other: LedgerMoney) throws -> LedgerMoney {
        try requireCompatible(other)
        let (difference, overflow) = minorUnits.subtractingReportingOverflow(other.minorUnits)
        guard !overflow else { throw LedgerError.arithmeticOverflow }
        return try LedgerMoney(minorUnits: difference, currency: currency, scale: scale)
    }

    private func requireCompatible(_ other: LedgerMoney) throws {
        guard currency == other.currency, scale == other.scale else {
            throw LedgerError.invalidMoneyAmount
        }
    }

    private static func parseDigits(_ bytes: ArraySlice<UInt8>) -> UInt64? {
        guard !bytes.isEmpty else { return 0 }
        var result: UInt64 = 0
        for byte in bytes {
            guard (48...57).contains(byte) else { return nil }
            let (timesTen, multiplyOverflow) = result.multipliedReportingOverflow(by: 10)
            let (next, addOverflow) = timesTen.addingReportingOverflow(UInt64(byte - 48))
            guard !multiplyOverflow, !addOverflow else { return nil }
            result = next
        }
        return result
    }
}

private func pow10(_ exponent: Int) -> Int64 {
    (0..<exponent).reduce(Int64(1)) { value, _ in value * 10 }
}

public enum LedgerSide: String, Codable, Sendable {
    case debit
    case credit
}

public struct LedgerPosting: Codable, Equatable, Sendable {
    public let accountID: String
    public let side: LedgerSide
    public let amount: LedgerMoney

    private enum CodingKeys: String, CodingKey { case accountID, side, amount }

    public init(accountID: String, side: LedgerSide, amount: LedgerMoney) throws {
        guard !accountID.isEmpty,
              accountID.utf8.count <= 128,
              !accountID.utf8.contains(0),
              amount.minorUnits > 0 else {
            throw LedgerError.invalidAccountIdentifier
        }
        self.accountID = accountID
        self.side = side
        self.amount = amount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accountID: container.decode(String.self, forKey: .accountID),
            side: container.decode(LedgerSide.self, forKey: .side),
            amount: container.decode(LedgerMoney.self, forKey: .amount)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(side, forKey: .side)
        try container.encode(amount, forKey: .amount)
    }
}

/// The result and all ledger postings produced by one local database operation.
public struct FinancialOperation: Sendable, Equatable {
    public let result: Data
    public let postings: [LedgerPosting]

    public init(result: Data, postings: [LedgerPosting] = []) throws {
        guard result.count <= 262_144, postings.count <= 1_000 else { throw LedgerError.invalidOperation }
        try Self.validate(postings)
        self.result = result
        self.postings = postings
    }

    public static func validate(_ postings: [LedgerPosting]) throws {
        guard postings.count <= 1_000 else { throw LedgerError.invalidOperation }
        if postings.isEmpty { return }
        guard postings.count >= 2 else { throw LedgerError.invalidOperation }
        struct Totals { var debit: Int64 = 0; var credit: Int64 = 0 }
        var totals: [String: Totals] = [:]
        for posting in postings {
            guard posting.amount.minorUnits > 0 else { throw LedgerError.invalidOperation }
            let key = "\(posting.amount.currency):\(posting.amount.scale)"
            var pair = totals[key, default: Totals()]
            switch posting.side {
            case .debit:
                let (value, overflow) = pair.debit.addingReportingOverflow(posting.amount.minorUnits)
                guard !overflow else { throw LedgerError.arithmeticOverflow }
                pair.debit = value
            case .credit:
                let (value, overflow) = pair.credit.addingReportingOverflow(posting.amount.minorUnits)
                guard !overflow else { throw LedgerError.arithmeticOverflow }
                pair.credit = value
            }
            totals[key] = pair
        }
        for key in totals.keys.sorted() {
            guard let pair = totals[key], pair.debit == pair.credit else {
                let components = key.split(separator: ":")
                throw LedgerError.unbalanced(
                    currency: components.first.map(String.init) ?? "",
                    scale: UInt8(components.last ?? "0") ?? 0
                )
            }
        }
    }
}

public struct FinancialOperationOutcome: Sendable, Equatable {
    public let operationID: UUID
    public let result: Data
    public let replayed: Bool

    public init(operationID: UUID, result: Data, replayed: Bool) {
        self.operationID = operationID
        self.result = result
        self.replayed = replayed
    }
}

/// Durable idempotency, optional ledger postings and the domain SQL callback
/// share one physical transaction in a conforming adapter. `canonicalParameters`
/// must be deterministic and include every input that changes the operation.
public protocol FinancialOperationStore: Sendable {
    func perform(
        scope: String,
        idempotencyKey: String,
        canonicalParameters: Data,
        resourceKeys: [String],
        _ operation: @Sendable (any SQLTransaction) async throws -> FinancialOperation
    ) async throws -> FinancialOperationOutcome

    /// Locks and reads the key so that a prior in-flight transaction has settled
    /// before returning `nil`. Use this after an unknown commit; do not retry first.
    func reconcile(
        scope: String,
        idempotencyKey: String,
        canonicalParameters: Data
    ) async throws -> FinancialOperationOutcome?

    /// Returns the ledger-derived credit-minus-debit balance, never a projection.
    func balance(accountID: String, currency: String, scale: UInt8) async throws -> LedgerMoney

    /// Reads a ledger-derived balance through the same transaction used by
    /// perform. Use this while the account is included in resourceKeys.
    func balance(
        accountID: String,
        currency: String,
        scale: UInt8,
        in transaction: any SQLTransaction
    ) async throws -> LedgerMoney
}

/// Resource-locking contract for adapters. Callers provide all resource keys
/// before reading mutable state; adapters acquire them in deterministic order.
public protocol FinancialResourceLocking: Sendable {
    func acquire(_ resourceKeys: [String], in transaction: any SQLTransaction) async throws
}

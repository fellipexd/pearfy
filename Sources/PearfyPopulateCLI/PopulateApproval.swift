import Crypto
import Foundation
import PearfyPopulateCore

public enum PopulateApprovalError: Error, Sendable, CustomStringConvertible {
    case missing
    case invalid
    case expired

    public var description: String {
        switch self {
        case .missing: "PEARFY_POPULATE_022: no local approval is recorded for this plan"
        case .invalid: "PEARFY_POPULATE_023: approval token does not match the plan, environment, or database"
        case .expired: "PEARFY_POPULATE_024: approval token has expired; approve the plan again"
        }
    }
}

/// A one-week, local-CLI-issued capability bound to one plan, environment,
/// and database. Only its digest is written to disk.
public struct PopulateApprovalStore: Sendable {
    private struct Record: Codable {
        let tokenHash: String
        let planHash: String
        let environment: PopulateEnvironment
        let databaseName: String
        let expiresAt: Date
    }

    private let directory: URL

    public init(projectRoot: URL) {
        directory = projectRoot.appendingPathComponent(".pearfy/populate/approvals", isDirectory: true)
    }

    @discardableResult
    public func issue(plan: PopulatePlan, confirmation: String) throws -> String {
        guard confirmation == "approve \(plan.planHash)" else { throw PopulateApprovalError.invalid }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let record = Record(
            tokenHash: Self.digest(token),
            planHash: plan.planHash,
            environment: plan.environment,
            databaseName: plan.databaseName,
            expiresAt: Date(timeIntervalSinceNow: 7 * 24 * 60 * 60)
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = recordURL(planHash: plan.planHash)
        try (encoder.encode(record) + Data([0x0a])).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }

    public func validate(
        token: String,
        plan: PopulatePlan,
        environment: PopulateEnvironment,
        databaseName: String
    ) throws {
        let url = recordURL(planHash: plan.planHash)
        guard FileManager.default.fileExists(atPath: url.path) else { throw PopulateApprovalError.missing }
        let record: Record
        do { record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url)) }
        catch { throw PopulateApprovalError.invalid }
        guard record.planHash == plan.planHash,
              record.environment == environment,
              record.databaseName == databaseName,
              Self.constantTimeEqual(record.tokenHash, Self.digest(token)) else {
            throw PopulateApprovalError.invalid
        }
        guard record.expiresAt > Date() else { throw PopulateApprovalError.expired }
    }

    private func recordURL(planHash: String) -> URL {
        directory.appendingPathComponent("\(planHash).json")
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let lhs = Array(left.utf8)
        let rhs = Array(right.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (leftByte, rightByte) in zip(lhs, rhs) { difference |= leftByte ^ rightByte }
        return difference == 0
    }
}

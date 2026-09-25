import Crypto
import Foundation
import PearfyWeb

public enum PearfyContractAuthorization: Codable, Equatable, Sendable {
    case permitAll
    case authenticated
    case roles([String])
}

public enum PearfyContractSchemaCoverage: String, Codable, Sendable {
    /// Route and policy metadata are available, but request/response type schemas
    /// have not yet been emitted. SDK generation must remain disabled.
    case routesAndPoliciesOnly
}

public struct PearfyContractGroup: Codable, Equatable, Sendable {
    public let name: String
    public let prefix: String
    public let contractVersion: String
    public let sdkTargets: [String]
}

public struct PearfyContractOperation: Codable, Equatable, Sendable {
    public let operationID: String
    public let group: String
    public let method: String
    public let path: String
    public let pathParameters: [String]
    public let authorization: PearfyContractAuthorization
}

/// A deterministic route-level contract snapshot. It deliberately does not
/// claim to be SDK-generatable until typed request/response schemas are emitted.
public struct PearfyContractIR: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let compilerVersion: String
    public let buildRevision: String
    public let schemaCoverage: PearfyContractSchemaCoverage
    public let groups: [PearfyContractGroup]
    public let operations: [PearfyContractOperation]

    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func schemaHash() throws -> String {
        SHA256.hash(data: try canonicalJSON()).map { String(format: "%02x", $0) }.joined()
    }

    public var canGenerateSDKs: Bool { false }
}

public enum PearfyConnectCompilerError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyBuildRevision
    case duplicateOperationID(String)

    public var description: String {
        switch self {
        case .emptyBuildRevision: "PEARFY_CONNECT_101: build revision is required for a contract snapshot"
        case .duplicateOperationID(let id): "PEARFY_CONNECT_102: duplicate operation id '\(id)'"
        }
    }
}

public struct PearfyConnectCompiler: Sendable {
    public let compilerVersion: String

    public init(compilerVersion: String = "0.1.0") {
        self.compilerVersion = compilerVersion
    }

    public func compile(router: HTTPRouter, buildRevision: String) async throws -> PearfyContractIR {
        guard !buildRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PearfyConnectCompilerError.emptyBuildRevision
        }

        let groups = await router.routeGroups()
            .filter { !$0.sdkTargets.isEmpty }
            .map { group in
                PearfyContractGroup(
                    name: group.name,
                    prefix: group.prefix,
                    contractVersion: group.contractVersion,
                    sdkTargets: group.sdkTargets.map(\.rawValue).sorted()
                )
            }
            .sorted { $0.name < $1.name }
        let exportedGroupNames = Set(groups.map(\.name))
        let groupPrefixes = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0.prefix) })
        let routeOperations = try await router.contractOperations()
            .filter { operation in
                guard let group = operation.group else { return false }
                return exportedGroupNames.contains(group)
            }

        let operations = routeOperations.map { operation -> PearfyContractOperation in
            let routePath = operation.group.flatMap { groupPrefixes[$0] }
                .map { Self.removingGroupPrefix($0, from: operation.path) }
                ?? operation.path
            let operationID = Self.operationID(
                group: operation.group ?? "",
                method: operation.method.description,
                path: routePath
            )
            let authorization: PearfyContractAuthorization
            switch operation.access {
            case .permitAll: authorization = .permitAll
            case .authenticated: authorization = .authenticated
            case .roles(let roles): authorization = .roles(roles.sorted())
            }
            return PearfyContractOperation(
                operationID: operationID,
                group: operation.group ?? "",
                method: operation.method.description,
                path: operation.path,
                pathParameters: Self.pathParameters(in: operation.path),
                authorization: authorization
            )
        }
        .sorted {
            if $0.group != $1.group { return $0.group < $1.group }
            if $0.method != $1.method { return $0.method < $1.method }
            return $0.path < $1.path
        }
        var operationIDs: Set<String> = []
        for operation in operations {
            guard operationIDs.insert(operation.operationID).inserted else {
                throw PearfyConnectCompilerError.duplicateOperationID(operation.operationID)
            }
        }

        return PearfyContractIR(
            formatVersion: 1,
            compilerVersion: compilerVersion,
            buildRevision: buildRevision,
            schemaCoverage: .routesAndPoliciesOnly,
            groups: groups,
            operations: operations
        )
    }

    private static func pathParameters(in path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).compactMap { segment in
            guard segment.first == "{", segment.last == "}" else { return nil }
            return String(segment.dropFirst().dropLast())
        }
    }

    private static func removingGroupPrefix(_ prefix: String, from path: String) -> String {
        guard path == prefix || path.hasPrefix(prefix + "/") else { return path }
        let suffix = String(path.dropFirst(prefix.count))
        return suffix.isEmpty ? "/" : suffix
    }

    private static func operationID(group: String, method: String, path: String) -> String {
        let pathIdentifier = path.split(separator: "/", omittingEmptySubsequences: true).map { segment in
            if segment.first == "{", segment.last == "}" {
                return "by_\(segment.dropFirst().dropLast())"
            }
            return String(segment)
        }.joined(separator: "_")
        return "\(group)_\(method.lowercased())_\(pathIdentifier.isEmpty ? "root" : pathIdentifier)"
    }
}

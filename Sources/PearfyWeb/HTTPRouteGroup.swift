import Foundation

public enum HTTPRouteSDKTarget: String, Codable, CaseIterable, Hashable, Sendable {
    case ios
    case android
    case typescript
}

/// Export metadata for a set of HTTP routes. Targets select generated clients;
/// they never grant authorization to a request.
public struct HTTPRouteGroup: Codable, Hashable, Sendable {
    public let name: String
    public let prefix: String
    public let sdkTargets: Set<HTTPRouteSDKTarget>
    public let contractVersion: String

    public init(
        name: String,
        prefix: String,
        sdkTargets: Set<HTTPRouteSDKTarget>,
        contractVersion: String = "1.0"
    ) {
        self.name = name
        self.prefix = prefix
        self.sdkTargets = sdkTargets
        self.contractVersion = contractVersion
    }
}

/// Stable route metadata for contract exporters; handlers and runtime secrets
/// are intentionally not exposed.
public struct HTTPRouteContractOperation: Sendable, Equatable {
    public let method: HTTPMethod
    public let path: String
    public let access: HTTPRouteAccess
    public let group: String?
    public let requestTypeName: String?
    public let responseTypeName: String?

    public init(
        method: HTTPMethod,
        path: String,
        access: HTTPRouteAccess,
        group: String?,
        requestTypeName: String? = nil,
        responseTypeName: String? = nil
    ) {
        self.method = method
        self.path = path
        self.access = access
        self.group = group
        self.requestTypeName = requestTypeName
        self.responseTypeName = responseTypeName
    }
}

public enum HTTPRouteGroupError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidName(String)
    case invalidPrefix(String)
    case invalidContractVersion(String)
    case conflictingDefinition(String)
    case duplicatePrefix(String)
    case notRegistered(String)

    public var description: String {
        switch self {
        case .invalidName(let name): "PEARFY_CONNECT_001: invalid route group name '\(name)'"
        case .invalidPrefix(let prefix): "PEARFY_CONNECT_002: invalid route group prefix '\(prefix)'"
        case .invalidContractVersion(let version): "PEARFY_CONNECT_003: invalid contract version '\(version)'"
        case .conflictingDefinition(let name): "PEARFY_CONNECT_004: conflicting definitions for route group '\(name)'"
        case .duplicatePrefix(let prefix): "PEARFY_CONNECT_005: route group prefix '\(prefix)' is already registered"
        case .notRegistered(let name): "PEARFY_CONNECT_006: route group '\(name)' is not registered"
        }
    }
}

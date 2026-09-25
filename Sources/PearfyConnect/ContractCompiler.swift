import Crypto
import Foundation
import PearfyWeb

public enum PearfyContractAuthorization: Codable, Equatable, Sendable {
    case permitAll
    case authenticated
    case roles([String])
}

public enum PearfyContractSchemaType: String, Codable, Equatable, Sendable {
    case object
    case string
    case integer
    case number
    case boolean
    case array
}

public struct PearfyContractSchemaReference: Codable, Equatable, Sendable {
    public let id: String
    public let nullable: Bool

    public init(id: String, nullable: Bool = false) {
        self.id = id
        self.nullable = nullable
    }
}

/// Framework-owned schema descriptor. Object fields and array items refer to
/// other descriptors by ID, allowing recursive models without embedding opaque
/// application JSON in the route contract.
public struct PearfyContractSchema: Codable, Equatable, Sendable {
    public let id: String
    public let type: PearfyContractSchemaType
    public let format: String?
    public let nullable: Bool
    public let properties: [String: PearfyContractSchemaReference]
    public let required: [String]
    public let items: PearfyContractSchemaReference?
    public let additionalProperties: Bool

    public init(
        id: String,
        type: PearfyContractSchemaType,
        format: String? = nil,
        nullable: Bool = false,
        properties: [String: PearfyContractSchemaReference] = [:],
        required: [String] = [],
        items: PearfyContractSchemaReference? = nil,
        additionalProperties: Bool = false
    ) {
        self.id = id
        self.type = type
        self.format = format
        self.nullable = nullable
        self.properties = properties
        self.required = required
        self.items = items
        self.additionalProperties = additionalProperties
    }
}

public enum PearfyContractSchemaCoverage: String, Codable, Sendable {
    case routesAndPoliciesOnly
    /// Schema references are resolved into the contract, but SDK generation
    /// remains disabled until the full client compatibility pipeline exists.
    case typedSchemaReferences
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
    public let requestSchema: PearfyContractSchemaReference?
    public let responseSchema: PearfyContractSchemaReference?
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
    public let schemas: [PearfyContractSchema]
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
    case duplicateSchemaID(String)
    case invalidSchemaID(String)
    case invalidSchemaDefinition(String)
    case missingSchema(String)

    public var description: String {
        switch self {
        case .emptyBuildRevision: "PEARFY_CONNECT_101: build revision is required for a contract snapshot"
        case .duplicateOperationID(let id): "PEARFY_CONNECT_102: duplicate operation id '\(id)'"
        case .duplicateSchemaID(let id): "PEARFY_CONNECT_103: duplicate schema id '\(id)'"
        case .invalidSchemaID(let id): "PEARFY_CONNECT_104: invalid schema id '\(id)'"
        case .invalidSchemaDefinition(let id): "PEARFY_CONNECT_105: invalid schema definition '\(id)'"
        case .missingSchema(let id): "PEARFY_CONNECT_106: schema '\(id)' is required by a route but is not registered"
        }
    }
}

public struct PearfyConnectCompiler: Sendable {
    public let compilerVersion: String

    public init(compilerVersion: String = "0.1.0") {
        self.compilerVersion = compilerVersion
    }

    public func compile(
        router: HTTPRouter,
        buildRevision: String,
        schemas suppliedSchemas: [PearfyContractSchema] = []
    ) async throws -> PearfyContractIR {
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

        var schemasByID = Dictionary(uniqueKeysWithValues: Self.builtInSchemas.map { ($0.id, $0) })
        for schema in suppliedSchemas {
            guard Self.isValidSchemaID(schema.id) else { throw PearfyConnectCompilerError.invalidSchemaID(schema.id) }
            guard schemasByID[schema.id] == nil else { throw PearfyConnectCompilerError.duplicateSchemaID(schema.id) }
            try Self.validate(schema)
            schemasByID[schema.id] = PearfyContractSchema(
                id: schema.id,
                type: schema.type,
                format: schema.format,
                nullable: schema.nullable,
                properties: schema.properties,
                required: schema.required.sorted(),
                items: schema.items,
                additionalProperties: schema.additionalProperties
            )
        }
        for schemaID in schemasByID.keys.sorted() {
            guard let schema = schemasByID[schemaID] else { continue }
            for reference in Self.references(in: schema).sorted(by: { $0.id < $1.id }) where schemasByID[reference.id] == nil {
                throw PearfyConnectCompilerError.missingSchema(reference.id)
            }
        }

        var referencedSchemaIDs: Set<String> = []
        var operations: [PearfyContractOperation] = []
        for operation in routeOperations {
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
            let requestSchema = try Self.schemaReference(for: operation.requestTypeName, available: &schemasByID)
            let responseSchema = try Self.schemaReference(for: operation.responseTypeName, available: &schemasByID)
            if let requestSchema { referencedSchemaIDs.insert(requestSchema.id) }
            if let responseSchema { referencedSchemaIDs.insert(responseSchema.id) }
            operations.append(PearfyContractOperation(
                operationID: operationID,
                group: operation.group ?? "",
                method: operation.method.description,
                path: operation.path,
                pathParameters: Self.pathParameters(in: operation.path),
                requestSchema: requestSchema,
                responseSchema: responseSchema,
                authorization: authorization
            ))
        }
        operations.sort {
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

        var includedSchemaIDs: Set<String> = []
        func includeSchema(_ id: String) throws {
            guard let schema = schemasByID[id] else { throw PearfyConnectCompilerError.missingSchema(id) }
            guard includedSchemaIDs.insert(id).inserted else { return }
            for reference in Self.references(in: schema).sorted(by: { $0.id < $1.id }) {
                try includeSchema(reference.id)
            }
        }
        for id in referencedSchemaIDs.sorted() { try includeSchema(id) }
        let includedSchemas = includedSchemaIDs.sorted().compactMap { schemasByID[$0] }

        return PearfyContractIR(
            formatVersion: 1,
            compilerVersion: compilerVersion,
            buildRevision: buildRevision,
            schemaCoverage: includedSchemas.isEmpty ? .routesAndPoliciesOnly : .typedSchemaReferences,
            groups: groups,
            schemas: includedSchemas,
            operations: operations
        )
    }

    private static let builtInSchemas: [PearfyContractSchema] = [
        PearfyContractSchema(id: "String", type: .string),
        PearfyContractSchema(id: "Int", type: .integer, format: "int64"),
        PearfyContractSchema(id: "Int32", type: .integer, format: "int32"),
        PearfyContractSchema(id: "Int64", type: .integer, format: "int64"),
        PearfyContractSchema(id: "Double", type: .number, format: "double"),
        PearfyContractSchema(id: "Float", type: .number, format: "float"),
        PearfyContractSchema(id: "Decimal", type: .number, format: "decimal"),
        PearfyContractSchema(id: "Bool", type: .boolean),
        PearfyContractSchema(id: "UUID", type: .string, format: "uuid"),
        PearfyContractSchema(id: "Data", type: .string, format: "byte")
    ]

    private static func schemaReference(
        for rawTypeName: String?,
        available schemas: inout [String: PearfyContractSchema]
    ) throws -> PearfyContractSchemaReference? {
        guard let rawTypeName else { return nil }
        var typeName = rawTypeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typeName != "Void", typeName != "()", typeName != "HTTPResponse", typeName != "PearfyWeb.HTTPResponse" else {
            return nil
        }
        let nullable: Bool
        if typeName.hasSuffix("?") {
            nullable = true
            typeName = String(typeName.dropLast())
        } else if typeName.hasPrefix("Optional<"), typeName.hasSuffix(">") {
            nullable = true
            typeName = String(typeName.dropFirst("Optional<".count).dropLast())
        } else {
            nullable = false
        }
        typeName = typeName.trimmingCharacters(in: .whitespacesAndNewlines)

        if let arrayElementType = arrayElementType(in: typeName) {
            guard let itemReference = try schemaReference(for: arrayElementType, available: &schemas) else {
                throw PearfyConnectCompilerError.invalidSchemaDefinition(typeName)
            }
            let digest = SHA256.hash(data: Data("\(itemReference.id):\(itemReference.nullable)".utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            let arraySchemaID = "Array_\(digest.prefix(16))"
            let arraySchema = PearfyContractSchema(
                id: arraySchemaID,
                type: .array,
                items: itemReference
            )
            if let existing = schemas[arraySchemaID] {
                guard existing == arraySchema else { throw PearfyConnectCompilerError.duplicateSchemaID(arraySchemaID) }
            } else {
                schemas[arraySchemaID] = arraySchema
            }
            return PearfyContractSchemaReference(id: arraySchemaID, nullable: nullable)
        }

        let builtinName = typeName.split(separator: ".").last.map(String.init) ?? typeName
        let id = schemas[typeName] != nil ? typeName : (schemas[builtinName] != nil ? builtinName : typeName)
        guard schemas[id] != nil else { throw PearfyConnectCompilerError.missingSchema(id) }
        return PearfyContractSchemaReference(id: id, nullable: nullable)
    }

    private static func arrayElementType(in typeName: String) -> String? {
        if typeName.hasPrefix("["), typeName.hasSuffix("]") {
            return String(typeName.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if typeName.hasPrefix("Array<"), typeName.hasSuffix(">") {
            return String(typeName.dropFirst("Array<".count).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func isValidSchemaID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard !bytes.isEmpty,
              bytes.count <= 128,
              (65...90).contains(bytes[0]) || (97...122).contains(bytes[0]) || bytes[0] == 95 else {
            return false
        }
        return bytes.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func validate(_ schema: PearfyContractSchema) throws {
        let propertyNames = Set(schema.properties.keys)
        let required = Set(schema.required)
        guard required.count == schema.required.count,
              required.isSubset(of: propertyNames) else {
            throw PearfyConnectCompilerError.invalidSchemaDefinition(schema.id)
        }
        switch schema.type {
        case .object:
            guard schema.items == nil else { throw PearfyConnectCompilerError.invalidSchemaDefinition(schema.id) }
        case .array:
            guard schema.items != nil, schema.properties.isEmpty, schema.required.isEmpty else {
                throw PearfyConnectCompilerError.invalidSchemaDefinition(schema.id)
            }
        case .string, .integer, .number, .boolean:
            guard schema.items == nil, schema.properties.isEmpty, schema.required.isEmpty,
                  !schema.additionalProperties else {
                throw PearfyConnectCompilerError.invalidSchemaDefinition(schema.id)
            }
        }
    }

    private static func references(in schema: PearfyContractSchema) -> [PearfyContractSchemaReference] {
        Array(schema.properties.values) + (schema.items.map { [$0] } ?? [])
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

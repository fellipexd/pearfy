import Foundation

public enum PearfyMigrationEntryMode: String, Codable, Sendable {
    case initialize = "init"
    case adopt
    case migrate
    case baseline
}

public enum PearfyMigrationState: String, Codable, CaseIterable, Sendable {
    case discovered
    case contracted
    case mapped
    case implemented
    case e2eGenerated = "e2e-generated"
    case verified
    case conflict
    case unsupported
    case ignored
}

public enum PearfyLegacyElementKind: String, Codable, CaseIterable, Sendable {
    case controller
    case service
    case repository
    case model
    case transaction
    case securityRule = "security-rule"
    case validation
    case job
    case event
    case externalDependency = "external-dependency"
}

public enum PearfyEvidenceConfidence: String, Codable, Hashable, Sendable {
    case low
    case medium
    case high
}

/// Codable JSON values used for request/response schemas without losing
/// unknown OpenAPI properties or examples.
public enum PearfyMigrationJSONValue: Codable, Equatable, Sendable {
    case object([String: PearfyMigrationJSONValue])
    case array([PearfyMigrationJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case boolean(Bool)
    case null

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var object: [String: PearfyMigrationJSONValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(PearfyMigrationJSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }
        if var container = try? decoder.unkeyedContainer() {
            var values: [PearfyMigrationJSONValue] = []
            while !container.isAtEnd { values.append(try container.decode(PearfyMigrationJSONValue.self)) }
            self = .array(values)
            return
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let values):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: DynamicCodingKey(stringValue: key)!)
            }
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .integer(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .boolean(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
        init?(intValue: Int) { self.intValue = intValue; stringValue = String(intValue) }
    }
}

public struct PearfyMigrationEvidence: Codable, Equatable, Hashable, Sendable {
    public let source: String
    public let path: String?
    public let confidence: PearfyEvidenceConfidence
    public let detail: String

    public init(
        source: String,
        path: String? = nil,
        confidence: PearfyEvidenceConfidence,
        detail: String
    ) {
        self.source = source
        self.path = path
        self.confidence = confidence
        self.detail = detail
    }
}

public struct PearfyMigrationConflict: Codable, Equatable, Hashable, Sendable {
    public let field: String
    public let candidates: [String]
    public let evidence: [PearfyMigrationEvidence]

    public init(field: String, candidates: [String], evidence: [PearfyMigrationEvidence]) {
        self.field = field
        self.candidates = candidates
        self.evidence = evidence
    }
}

public struct PearfyLegacyElementContract: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: PearfyLegacyElementKind
    public let name: String
    public var domain: String?
    public var state: PearfyMigrationState
    public var attributes: [String: PearfyMigrationJSONValue]
    public var evidence: [PearfyMigrationEvidence]
    public var conflicts: [PearfyMigrationConflict]

    public init(
        id: String,
        kind: PearfyLegacyElementKind,
        name: String,
        domain: String? = nil,
        state: PearfyMigrationState = .discovered,
        attributes: [String: PearfyMigrationJSONValue] = [:],
        evidence: [PearfyMigrationEvidence] = [],
        conflicts: [PearfyMigrationConflict] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.domain = domain
        self.state = state
        self.attributes = attributes
        self.evidence = evidence
        self.conflicts = conflicts
    }
}

public struct PearfyLegacyResponseContract: Codable, Equatable, Sendable {
    public let description: String?
    public let contentTypes: [String]
    public let schema: PearfyMigrationJSONValue?
    public let examples: [String: PearfyMigrationJSONValue]

    public init(
        description: String? = nil,
        contentTypes: [String] = [],
        schema: PearfyMigrationJSONValue? = nil,
        examples: [String: PearfyMigrationJSONValue] = [:]
    ) {
        self.description = description
        self.contentTypes = contentTypes.sorted()
        self.schema = schema
        self.examples = examples
    }
}

public struct PearfyLegacyParameterContract: Codable, Equatable, Sendable {
    public let name: String
    public let location: String
    public let required: Bool
    public let schema: PearfyMigrationJSONValue?
    public let example: PearfyMigrationJSONValue?

    public init(name: String, location: String, required: Bool, schema: PearfyMigrationJSONValue? = nil, example: PearfyMigrationJSONValue? = nil) {
        self.name = name
        self.location = location
        self.required = required
        self.schema = schema
        self.example = example
    }
}

public struct PearfyLegacyRouteContract: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var domain: String?
    public let method: String
    public let path: String
    public var parameters: [PearfyLegacyParameterContract]
    public var request: PearfyMigrationJSONValue?
    public var responses: [String: PearfyLegacyResponseContract]
    public var security: [String]
    public var implementation: [String: String]
    public var evidence: [PearfyMigrationEvidence]
    public var conflicts: [PearfyMigrationConflict]
    public var state: PearfyMigrationState

    public init(
        id: String,
        domain: String? = nil,
        method: String,
        path: String,
        parameters: [PearfyLegacyParameterContract] = [],
        request: PearfyMigrationJSONValue? = nil,
        responses: [String: PearfyLegacyResponseContract] = [:],
        security: [String] = [],
        implementation: [String: String] = [:],
        evidence: [PearfyMigrationEvidence] = [],
        conflicts: [PearfyMigrationConflict] = [],
        state: PearfyMigrationState = .discovered
    ) {
        self.id = id
        self.domain = domain
        self.method = method.uppercased()
        self.path = path
        self.parameters = parameters.sorted { ($0.location, $0.name) < ($1.location, $1.name) }
        self.request = request
        self.responses = responses
        self.security = Array(Set(security)).sorted()
        self.implementation = implementation
        self.evidence = Self.sortedEvidence(evidence)
        self.conflicts = conflicts.sorted { $0.field < $1.field }
        self.state = state
    }

    public var key: String { "\(method) \(path)" }

    private static func sortedEvidence(_ values: [PearfyMigrationEvidence]) -> [PearfyMigrationEvidence] {
        Array(Set(values)).sorted {
            ($0.source, $0.path ?? "", $0.detail) < ($1.source, $1.path ?? "", $1.detail)
        }
    }
}

public struct PearfyLegacyContractDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var origin: PearfyMigrationOrigin
    public var routes: [PearfyLegacyRouteContract]
    public var elements: [PearfyLegacyElementContract]
    public var components: [String: PearfyMigrationJSONValue]
    public var evidence: [PearfyMigrationEvidence]
    public var analyzedFiles: Int

    public init(
        schemaVersion: Int = 1,
        origin: PearfyMigrationOrigin = PearfyMigrationOrigin(),
        routes: [PearfyLegacyRouteContract] = [],
        elements: [PearfyLegacyElementContract] = [],
        components: [String: PearfyMigrationJSONValue] = [:],
        evidence: [PearfyMigrationEvidence] = [],
        analyzedFiles: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.origin = origin
        self.routes = routes.sorted { $0.key < $1.key }
        self.elements = elements.sorted { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
        self.components = components
        self.evidence = Array(Set(evidence)).sorted {
            ($0.source, $0.path ?? "", $0.detail) < ($1.source, $1.path ?? "", $1.detail)
        }
        self.analyzedFiles = analyzedFiles
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, origin, routes, elements, components, evidence, analyzedFiles
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
            origin: try values.decodeIfPresent(PearfyMigrationOrigin.self, forKey: .origin) ?? PearfyMigrationOrigin(),
            routes: try values.decodeIfPresent([PearfyLegacyRouteContract].self, forKey: .routes) ?? [],
            elements: try values.decodeIfPresent([PearfyLegacyElementContract].self, forKey: .elements) ?? [],
            components: try values.decodeIfPresent([String: PearfyMigrationJSONValue].self, forKey: .components) ?? [:],
            evidence: try values.decodeIfPresent([PearfyMigrationEvidence].self, forKey: .evidence) ?? [],
            analyzedFiles: try values.decodeIfPresent(Int.self, forKey: .analyzedFiles) ?? 0
        )
    }
}

public struct PearfyMigrationOrigin: Codable, Equatable, Sendable {
    public var type: String
    public var language: String?
    public var framework: String?
    public var confidence: PearfyEvidenceConfidence

    public init(type: String = "unknown", language: String? = nil, framework: String? = nil, confidence: PearfyEvidenceConfidence = .low) {
        self.type = type
        self.language = language
        self.framework = framework
        self.confidence = confidence
    }
}

public struct PearfyMigrationProgress: Codable, Equatable, Sendable {
    public var discovered: Int
    public var contracted: Int
    public var mapped: Int
    public var implemented: Int
    public var e2eGenerated: Int
    public var e2ePassing: Int
    public var contractClosed: Int
    public var conflicts: Int
    public var unsupported: Int
    public var ignored: Int
    public var total: Int
    public var elements: [String: PearfyMigrationElementProgress]

    public init(routes: [PearfyLegacyRouteContract], elements: [PearfyLegacyElementContract] = []) {
        discovered = routes.filter { $0.state == .discovered }.count
        contracted = routes.filter { $0.state == .contracted }.count
        mapped = routes.filter { $0.state == .mapped }.count
        implemented = routes.filter { $0.state == .implemented }.count
        e2eGenerated = routes.filter { $0.state == .e2eGenerated }.count
        e2ePassing = routes.filter { $0.state == .verified }.count
        contractClosed = e2ePassing
        conflicts = routes.filter { $0.state == .conflict || !$0.conflicts.isEmpty }.count
        unsupported = routes.filter { $0.state == .unsupported }.count
        ignored = routes.filter { $0.state == .ignored }.count
        total = routes.count
        self.elements = Dictionary(grouping: elements, by: { $0.kind.rawValue }).mapValues(PearfyMigrationElementProgress.init(elements:))
    }

    private enum CodingKeys: String, CodingKey {
        case discovered, contracted, mapped, implemented, e2eGenerated, e2ePassing, contractClosed, conflicts, unsupported, ignored, total, elements
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        discovered = try values.decodeIfPresent(Int.self, forKey: .discovered) ?? 0
        contracted = try values.decodeIfPresent(Int.self, forKey: .contracted) ?? 0
        mapped = try values.decodeIfPresent(Int.self, forKey: .mapped) ?? 0
        implemented = try values.decodeIfPresent(Int.self, forKey: .implemented) ?? 0
        e2eGenerated = try values.decodeIfPresent(Int.self, forKey: .e2eGenerated) ?? 0
        e2ePassing = try values.decodeIfPresent(Int.self, forKey: .e2ePassing) ?? 0
        contractClosed = try values.decodeIfPresent(Int.self, forKey: .contractClosed) ?? 0
        conflicts = try values.decodeIfPresent(Int.self, forKey: .conflicts) ?? 0
        unsupported = try values.decodeIfPresent(Int.self, forKey: .unsupported) ?? 0
        ignored = try values.decodeIfPresent(Int.self, forKey: .ignored) ?? 0
        total = try values.decodeIfPresent(Int.self, forKey: .total) ?? 0
        elements = try values.decodeIfPresent([String: PearfyMigrationElementProgress].self, forKey: .elements) ?? [:]
    }
}

public struct PearfyMigrationElementProgress: Codable, Equatable, Sendable {
    public let discovered: Int
    public let contracted: Int
    public let mapped: Int
    public let implemented: Int
    public let verified: Int
    public let conflicts: Int
    public let unsupported: Int
    public let ignored: Int
    public let total: Int

    public init(elements: [PearfyLegacyElementContract]) {
        discovered = elements.filter { $0.state == .discovered }.count
        contracted = elements.filter { $0.state == .contracted }.count
        mapped = elements.filter { $0.state == .mapped }.count
        implemented = elements.filter { $0.state == .implemented }.count
        verified = elements.filter { $0.state == .verified }.count
        conflicts = elements.filter { $0.state == .conflict || !$0.conflicts.isEmpty }.count
        unsupported = elements.filter { $0.state == .unsupported }.count
        ignored = elements.filter { $0.state == .ignored }.count
        total = elements.count
    }
}

public struct PearfyProjectManifest: Codable, Equatable, Sendable {
    public struct Project: Codable, Equatable, Sendable {
        public var name: String
        public var mode: PearfyMigrationEntryMode
        public init(name: String, mode: PearfyMigrationEntryMode) { self.name = name; self.mode = mode }
    }

    public struct Versions: Codable, Equatable, Sendable {
        public var frameworkVersion: String
        public var cliVersion: String
        public init(frameworkVersion: String = "0.1.0", cliVersion: String = "0.1.0") {
            self.frameworkVersion = frameworkVersion
            self.cliVersion = cliVersion
        }
    }

    public struct Architecture: Codable, Equatable, Sendable {
        public var style: String
        public var profile: String
        public var decisions: [String: PearfyMigrationJSONValue]
        public init(style: String = "clean", profile: String, decisions: [String: PearfyMigrationJSONValue] = [:]) {
            self.style = style
            self.profile = profile
            self.decisions = decisions
        }

        private enum CodingKeys: String, CodingKey {
            case style
            case profile
            case decisions
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            style = try container.decodeIfPresent(String.self, forKey: .style) ?? "clean"
            profile = try container.decode(String.self, forKey: .profile)
            decisions = try container.decodeIfPresent(
                [String: PearfyMigrationJSONValue].self,
                forKey: .decisions
            ) ?? [:]
        }
    }

    public struct Migration: Codable, Equatable, Sendable {
        public var strategy: String
        public var contractPath: String
        public var status: PearfyMigrationProgress
        public init(strategy: String = "progressive", contractPath: String = ".pearfy/migration/legacy-contract.yml", status: PearfyMigrationProgress) {
            self.strategy = strategy
            self.contractPath = contractPath
            self.status = status
        }
    }

    public let schemaVersion: Int
    public var project: Project
    public var pearfy: Versions
    public var provenance: String
    public var origin: PearfyMigrationOrigin
    public var evidence: [String: [PearfyMigrationEvidence]]
    public var architecture: Architecture
    public var migration: Migration
    public var modules: [String: Bool]

    public init(
        schemaVersion: Int = 1,
        project: Project,
        pearfy: Versions = Versions(),
        provenance: String,
        origin: PearfyMigrationOrigin,
        evidence: [String: [PearfyMigrationEvidence]],
        architecture: Architecture,
        migration: Migration,
        modules: [String: Bool]
    ) {
        self.schemaVersion = schemaVersion
        self.project = project
        self.pearfy = pearfy
        self.provenance = provenance
        self.origin = origin
        self.evidence = evidence
        self.architecture = architecture
        self.migration = migration
        self.modules = modules
    }
}

enum PearfyMigrationDocumentError: Error, Sendable, Equatable, CustomStringConvertible {
    case tooLarge(String)
    case invalidDocument(String)

    var description: String {
        switch self {
        case .tooLarge(let path): "PEARFY_MIGRATION_001: migration document exceeds the 4 MiB limit: \(path)"
        case .invalidDocument(let path): "PEARFY_MIGRATION_002: invalid JSON/YAML migration document: \(path)"
        }
    }
}

enum PearfyMigrationDocumentStore {
    static let maximumBytes = 4 * 1_024 * 1_024

    static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw PearfyMigrationDocumentError.tooLarge(url.path) }
        if let value = try? JSONDecoder().decode(type, from: data) { return value }
        do {
            let yamlValue = try PearfyYAMLSubset.parse(data)
            let json = try JSONSerialization.data(withJSONObject: yamlValue, options: [.fragmentsAllowed, .sortedKeys])
            return try JSONDecoder().decode(type, from: json)
        } catch {
            throw PearfyMigrationDocumentError.invalidDocument(url.path)
        }
    }

    /// JSON is a valid YAML 1.2 document and avoids hand-built YAML escaping.
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data([0x0a])
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let bytes = try encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
    }
}

/// Bounded YAML 1.2 block subset for human-edited manifests. Generated files
/// use JSON syntax, which is also valid YAML 1.2.
private enum PearfyYAMLSubset {
    private struct Line {
        let number: Int
        let indent: Int
        let text: String
    }

    static func parse(_ data: Data) throws -> Any {
        guard let text = String(data: data, encoding: .utf8) else { throw ParseError.invalid }
        let lines = try tokenize(text)
        guard !lines.isEmpty else { throw ParseError.invalid }
        var cursor = 0
        let value = try parseNode(lines, cursor: &cursor, indent: lines[0].indent)
        guard cursor == lines.count else { throw ParseError.invalid }
        return value
    }

    private static func tokenize(_ text: String) throws -> [Line] {
        var result: [Line] = []
        for (offset, raw) in text.components(separatedBy: .newlines).enumerated() {
            guard !raw.contains("\t") else { throw ParseError.invalid }
            let cleaned = stripComment(raw)
            let leading = cleaned.prefix(while: { $0 == " " }).count
            let body = String(cleaned.dropFirst(leading)).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty || body == "---" || body == "..." { continue }
            result.append(Line(number: offset + 1, indent: leading, text: body))
        }
        return result
    }

    private static func parseNode(_ lines: [Line], cursor: inout Int, indent: Int) throws -> Any {
        guard cursor < lines.count, lines[cursor].indent == indent else { throw ParseError.invalid }
        if isSequenceLine(lines[cursor].text) { return try parseSequence(lines, cursor: &cursor, indent: indent) }
        return try parseMapping(lines, cursor: &cursor, indent: indent)
    }

    private static func parseMapping(_ lines: [Line], cursor: inout Int, indent: Int) throws -> [String: Any] {
        var result: [String: Any] = [:]
        while cursor < lines.count, lines[cursor].indent == indent, !isSequenceLine(lines[cursor].text) {
            let line = lines[cursor]
            guard let (key, rawValue) = splitPair(line.text), !key.isEmpty,
                  result[key] == nil else { throw ParseError.invalid }
            cursor += 1
            if rawValue.isEmpty {
                result[key] = try parseChildOrNull(lines, cursor: &cursor, indent: indent)
            } else {
                result[key] = try scalar(rawValue)
            }
        }
        return result
    }

    private static func parseSequence(_ lines: [Line], cursor: inout Int, indent: Int) throws -> [Any] {
        var result: [Any] = []
        while cursor < lines.count, lines[cursor].indent == indent, isSequenceLine(lines[cursor].text) {
            let line = lines[cursor]
            let content = String(line.text.dropFirst()).trimmingCharacters(in: .whitespaces)
            cursor += 1
            if content.isEmpty {
                result.append(try parseChildOrNull(lines, cursor: &cursor, indent: indent))
                continue
            }
            if let (key, rawValue) = splitPair(content) {
                var item: [String: Any] = [:]
                let childIndent = indent + 2
                if rawValue.isEmpty {
                    item[key] = try parseChildOrNull(lines, cursor: &cursor, indent: childIndent - 2)
                } else {
                    item[key] = try scalar(rawValue)
                }
                if cursor < lines.count, lines[cursor].indent > indent {
                    let continuationIndent = lines[cursor].indent
                    let continuation = try parseMapping(lines, cursor: &cursor, indent: continuationIndent)
                    for (continuationKey, value) in continuation {
                        guard item[continuationKey] == nil else { throw ParseError.invalid }
                        item[continuationKey] = value
                    }
                }
                result.append(item)
            } else {
                result.append(try scalar(content))
                guard cursor == lines.count || lines[cursor].indent <= indent else { throw ParseError.invalid }
            }
        }
        return result
    }

    private static func parseChildOrNull(_ lines: [Line], cursor: inout Int, indent: Int) throws -> Any {
        guard cursor < lines.count, lines[cursor].indent > indent else { return NSNull() }
        let childIndent = lines[cursor].indent
        return try parseNode(lines, cursor: &cursor, indent: childIndent)
    }

    private static func splitPair(_ text: String) -> (String, String)? {
        var quote: Character?
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if escaped { escaped = false; continue }
            if character == "\\", quote == "\"" { escaped = true; continue }
            if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                continue
            }
            if character == ":", quote == nil {
                let key = String(text[..<index]).trimmingCharacters(in: .whitespaces)
                let value = String(text[text.index(after: index)...]).trimmingCharacters(in: .whitespaces)
                return (unquote(key), value)
            }
        }
        return nil
    }

    private static func scalar(_ value: String) throws -> Any {
        let value = value.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return "" }
        if value.first == "\"", let data = value.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        if value.first == "'", value.last == "'", value.count >= 2 {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        switch value.lowercased() {
        case "true": return true
        case "false": return false
        case "null", "~": return NSNull()
        default: break
        }
        if let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           object is [String: Any] || object is [Any] {
            return object
        }
        if let integer = Int64(value) { return integer }
        if let number = Double(value), number.isFinite { return number }
        return value
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.first == "\"", value.last == "\"",
           let data = value.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return value
    }

    private static func isSequenceLine(_ value: String) -> Bool {
        value == "-" || value.hasPrefix("- ")
    }

    private static func stripComment(_ value: String) -> String {
        var quote: Character?
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if escaped { escaped = false; continue }
            if character == "\\", quote == "\"" { escaped = true; continue }
            if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                continue
            }
            if character == "#", quote == nil,
               index == value.startIndex || value[value.index(before: index)].isWhitespace {
                return String(value[..<index])
            }
        }
        return value
    }

    private enum ParseError: Error { case invalid }
}

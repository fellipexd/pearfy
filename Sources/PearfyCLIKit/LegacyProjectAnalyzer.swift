import Foundation
import CoreFoundation

public enum PearfyLegacyAnalyzerError: Error, Sendable, Equatable, CustomStringConvertible {
    case projectDirectoryRequired(String)
    case sourceLimitExceeded

    public var description: String {
        switch self {
        case .projectDirectoryRequired(let path): "PEARFY_MIGRATION_010: project directory does not exist: \(path)"
        case .sourceLimitExceeded: "PEARFY_MIGRATION_011: legacy analysis exceeded its bounded source limits"
        }
    }
}

/// Bounded, evidence-producing source analyzer. It extracts contracts rather
/// than rewriting or copying legacy source code.
public struct PearfyLegacyProjectAnalyzer: Sendable {
    public let maximumFiles: Int
    public let maximumFileBytes: Int
    public let maximumTotalBytes: Int

    public init(maximumFiles: Int = 5_000, maximumFileBytes: Int = 1_048_576, maximumTotalBytes: Int = 32 * 1_024 * 1_024) {
        self.maximumFiles = max(1, maximumFiles)
        self.maximumFileBytes = max(1, maximumFileBytes)
        self.maximumTotalBytes = max(maximumFileBytes, maximumTotalBytes)
    }

    public func analyze(projectRoot: URL, declaredFramework: String? = nil) throws -> PearfyLegacyContractDocument {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PearfyLegacyAnalyzerError.projectDirectoryRequired(root.path)
        }

        let files = try collectFiles(root: root)
        var textByPath: [String: String] = [:]
        var analyzedBytes = 0
        var languages: [String: Int] = [:]
        var frameworks: [String: Int] = [:]
        var evidence: [PearfyMigrationEvidence] = []
        var routes: [String: PearfyLegacyRouteContract] = [:]
        var elements: [String: PearfyLegacyElementContract] = [:]
        var components: [String: PearfyMigrationJSONValue] = [:]
        var pearfyDetected = false
        let historicalPaths = gitHistoryPaths(root: root)

        for historicalPath in historicalPaths {
            let filename = URL(fileURLWithPath: historicalPath).lastPathComponent.lowercased()
            let extensionName = URL(fileURLWithPath: historicalPath).pathExtension.lowercased()
            if filename == "pom.xml" || ["build.gradle", "build.gradle.kts"].contains(filename) {
                frameworks["spring-boot", default: 0] += 2
                evidence.append(PearfyMigrationEvidence(
                    source: "git-history",
                    path: historicalPath,
                    confidence: .medium,
                    detail: "recent history contains a Spring build descriptor path"
                ))
            }
            if let language = language(for: extensionName) { languages[language, default: 0] += 1 }
        }

        for file in files {
            let relativePath = relative(file, to: root)
            let ext = file.pathExtension.lowercased()
            guard isAnalyzableTextExtension(ext) else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            guard let size = values.fileSize, size <= maximumFileBytes else { continue }
            guard analyzedBytes + size <= maximumTotalBytes else { throw PearfyLegacyAnalyzerError.sourceLimitExceeded }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            guard let text = String(data: data, encoding: .utf8) else { continue }
            analyzedBytes += data.count
            textByPath[relativePath] = text
            if let language = language(for: ext) { languages[language, default: 0] += 1 }
        }

        guard textByPath.count <= maximumFiles else {
            throw PearfyLegacyAnalyzerError.sourceLimitExceeded
        }

        let sortedPaths = textByPath.keys.sorted()
        for path in sortedPaths {
            guard let text = textByPath[path] else { continue }
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            if path == "Package.swift", text.localizedCaseInsensitiveContains("Pearfy") {
                pearfyDetected = true
                evidence.append(PearfyMigrationEvidence(
                    source: "pearfy-source",
                    path: path,
                    confidence: .high,
                    detail: "Swift package declares or consumes Pearfy products"
                ))
            }
            if path == "pom.xml" || path.hasSuffix("/pom.xml") {
                if text.localizedCaseInsensitiveContains("spring-boot") { frameworks["spring-boot", default: 0] += 4 }
            }
            if ["build.gradle", "build.gradle.kts"].contains(URL(fileURLWithPath: path).lastPathComponent),
               text.localizedCaseInsensitiveContains("org.springframework.boot") {
                frameworks["spring-boot", default: 0] += 4
            }
            if path == "package.json" || path.hasSuffix("/package.json") {
                if text.localizedCaseInsensitiveContains("@nestjs/") { frameworks["nestjs", default: 0] += 4 }
                if text.localizedCaseInsensitiveContains("express") { frameworks["express", default: 0] += 3 }
                if text.localizedCaseInsensitiveContains("fastify") { frameworks["fastify", default: 0] += 3 }
            }
            if path == "composer.json" || path.hasSuffix("/composer.json") {
                if text.localizedCaseInsensitiveContains("laravel/framework") { frameworks["laravel", default: 0] += 4 }
                if text.localizedCaseInsensitiveContains("symfony/") { frameworks["symfony", default: 0] += 3 }
            }
            if ext == "csproj", text.localizedCaseInsensitiveContains("Microsoft.AspNetCore") {
                frameworks["aspnet-core", default: 0] += 4
            }
            if ["requirements.txt", "pyproject.toml"].contains(URL(fileURLWithPath: path).lastPathComponent.lowercased()),
               text.localizedCaseInsensitiveContains("fastapi") {
                frameworks["fastapi", default: 0] += 4
            }
            if ext == "csproj", text.localizedCaseInsensitiveContains("Microsoft.AspNetCore") {
                frameworks["aspnet-core", default: 0] += 4
            }
            if ["requirements.txt", "pyproject.toml"].contains(URL(fileURLWithPath: path).lastPathComponent.lowercased()),
               text.localizedCaseInsensitiveContains("fastapi") {
                frameworks["fastapi", default: 0] += 4
            }

            let fileURL = root.appendingPathComponent(path)
            if isOpenAPIDocument(path: path, text: text),
               let document = try? PearfyMigrationDocumentStore.load(PearfyMigrationJSONValue.self, from: fileURL) {
                let extracted = openAPIRoutes(document, path: path)
                let schemas = openAPIComponents(document)
                components.merge(schemas) { current, _ in current }
                for name in schemas.keys.sorted() {
                    merge(PearfyLegacyElementContract(
                        id: "model:\(name)",
                        kind: .model,
                        name: name,
                        state: .contracted,
                        evidence: [PearfyMigrationEvidence(source: "openapi", path: path, confidence: .high, detail: "OpenAPI component schema")]
                    ), into: &elements)
                }
                for route in extracted { merge(route, into: &routes) }
                if !extracted.isEmpty {
                    evidence.append(PearfyMigrationEvidence(
                        source: "openapi",
                        path: path,
                        confidence: .high,
                        detail: "OpenAPI/Swagger path and operation metadata"
                    ))
                }
            }

            if isPostmanCollection(path: path, text: text),
               let document = try? PearfyMigrationDocumentStore.load(PearfyMigrationJSONValue.self, from: fileURL) {
                let extracted = postmanRoutes(document, path: path)
                for route in extracted { merge(route, into: &routes) }
                if !extracted.isEmpty {
                    evidence.append(PearfyMigrationEvidence(
                        source: "postman",
                        path: path,
                        confidence: .medium,
                        detail: "Postman collection request method/path metadata; credential and example values omitted"
                    ))
                }
            }

            if ext == "java" || ext == "kt" {
                let extracted = springRoutes(in: text, path: path)
                for route in extracted { merge(route, into: &routes) }
                for element in springElements(in: text, path: path) { merge(element, into: &elements) }
                if text.contains("@SpringBootApplication") || text.contains("@RestController") || text.contains("@RequestMapping") {
                    frameworks["spring-boot", default: 0] += 1
                    evidence.append(PearfyMigrationEvidence(
                        source: "spring-source",
                        path: path,
                        confidence: extracted.isEmpty ? .medium : .high,
                        detail: extracted.isEmpty ? "Spring application/controller indicators" : "Spring route mapping annotations"
                    ))
                }
            }

            if ext == "js" || ext == "jsx" || ext == "ts" || ext == "tsx" {
                let extracted = nodeRoutes(in: text, path: path)
                for route in extracted { merge(route, into: &routes) }
                if ext == "ts" || ext == "tsx" {
                    for route in nestRoutes(in: text, path: path) { merge(route, into: &routes) }
                }
                if text.contains("http.createServer") || text.contains("req.method") || text.contains("request.method") {
                    evidence.append(PearfyMigrationEvidence(
                        source: "generic-nodejs",
                        path: path,
                        confidence: extracted.isEmpty ? .low : .medium,
                        detail: extracted.isEmpty ? "frameworkless HTTP server indicators" : "HTTP method/path route declarations"
                    ))
                }
            }

            if ext == "php" {
                let extracted = phpRoutes(in: text, path: path)
                for route in extracted { merge(route, into: &routes) }
                for route in laravelRoutes(in: text, path: path) { merge(route, into: &routes) }
                if text.contains("$_SERVER['REQUEST_METHOD']") || text.contains("$_SERVER[\"REQUEST_METHOD\"]") {
                    evidence.append(PearfyMigrationEvidence(
                        source: "generic-php",
                        path: path,
                        confidence: extracted.isEmpty ? .low : .medium,
                        detail: extracted.isEmpty ? "frameworkless PHP HTTP entry point" : "request method/URI comparisons"
                    ))
                }
            }
            if ext == "py" {
                let extracted = fastAPIRoutes(in: text, path: path)
                for route in extracted { merge(route, into: &routes) }
                if text.contains("FastAPI(") || text.contains("APIRouter(") {
                    frameworks["fastapi", default: 0] += 1
                    evidence.append(PearfyMigrationEvidence(
                        source: "fastapi-source",
                        path: path,
                        confidence: extracted.isEmpty ? .medium : .high,
                        detail: extracted.isEmpty ? "FastAPI application/router indicator" : "FastAPI route decorator"
                    ))
                }
            }
            if ext == "cs" {
                let extracted = aspNetRoutes(in: text, path: path)
                for route in extracted { merge(route, into: &routes) }
                for element in aspNetSecurityElements(in: text, path: path) { merge(element, into: &elements) }
                if text.contains("[ApiController]") || text.contains("ControllerBase") {
                    frameworks["aspnet-core", default: 0] += 1
                    evidence.append(PearfyMigrationEvidence(
                        source: "aspnet-source",
                        path: path,
                        confidence: extracted.isEmpty ? .medium : .high,
                        detail: extracted.isEmpty ? "ASP.NET Core controller indicator" : "HTTP verb route attributes"
                    ))
                }
            }
            if ext == "go" {
                for route in goRoutes(in: text, path: path) { merge(route, into: &routes) }
            }
            if ext == "sql" {
                for element in sqlTableElements(in: text, path: path) { merge(element, into: &elements) }
                let filename = URL(fileURLWithPath: path).lastPathComponent
                if filename.range(of: #"^V[0-9]+__|^R__"#, options: .regularExpression) != nil {
                    evidence.append(PearfyMigrationEvidence(
                        source: "flyway-migration",
                        path: path,
                        confidence: .medium,
                        detail: "Flyway-style migration artifact; SQL statements are not copied into evidence"
                    ))
                }
            }
            if ext == "xml", text.contains("databaseChangeLog") {
                for element in liquibaseTableElements(in: text, path: path) { merge(element, into: &elements) }
                evidence.append(PearfyMigrationEvidence(
                    source: "liquibase-migration",
                    path: path,
                    confidence: .medium,
                    detail: "Liquibase change log detected"
                ))
            }
        }

        if !sortedPaths.contains(where: { isOpenAPIPotentialPath($0) }) {
            evidence.append(PearfyMigrationEvidence(
                source: "project-scan",
                confidence: .low,
                detail: "No recognized OpenAPI/Swagger document was found"
            ))
        }
        if routes.isEmpty {
            evidence.append(PearfyMigrationEvidence(
                source: "project-scan",
                confidence: .low,
                detail: "No route could be extracted automatically; review source evidence and add contract entries manually"
            ))
        }

        let language = languages.max { $0.value < $1.value }?.key
        let framework = declaredFramework?.lowercased() ?? frameworks.max { $0.value < $1.value }?.key
        let originConfidence: PearfyEvidenceConfidence = declaredFramework != nil || (frameworks[framework ?? ""] ?? 0) >= 4 ? .high : (framework == nil ? .low : .medium)
        let detectedOrigin = PearfyMigrationOrigin(
            type: framework == nil ? (pearfyDetected ? "pearfy" : (language == nil ? "unknown" : "legacy")) : "legacy",
            language: language,
            framework: framework,
            confidence: pearfyDetected && framework == nil ? .high : originConfidence
        )
        evidence.append(PearfyMigrationEvidence(
            source: "project-scan",
            confidence: originConfidence,
            detail: framework.map { "Detected likely origin framework \($0)" } ?? "Detected language \(language ?? "unknown") without a supported framework signature"
        ))

        return PearfyLegacyContractDocument(
            origin: detectedOrigin,
            routes: Array(routes.values),
            elements: Array(elements.values),
            components: components,
            evidence: evidence,
            analyzedFiles: textByPath.count
        )
    }

    private func collectFiles(root: URL) throws -> [URL] {
        let skipped: Set<String> = [".git", ".build", ".swiftpm", "node_modules", "vendor", "target", "dist", "build", ".gradle"]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let file as URL in enumerator {
            let relativePath = relative(file, to: root)
            let components = relativePath.split(separator: "/").map(String.init)
            if let skippedComponent = components.first(where: skipped.contains) {
                enumerator.skipDescendants()
                _ = skippedComponent
                continue
            }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isRegularFile == true {
                files.append(file)
                if files.count > maximumFiles { throw PearfyLegacyAnalyzerError.sourceLimitExceeded }
            }
        }
        return files.sorted { relative($0, to: root) < relative($1, to: root) }
    }

    private func gitHistoryPaths(root: URL) -> Set<String> {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path, "log", "--max-count=20", "--format=", "--name-only", "--no-renames"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            let output = pipe.fileHandleForReading
            var bytes = Data()
            while let chunk = try output.read(upToCount: 4_096), !chunk.isEmpty {
                guard bytes.count + chunk.count <= 1_048_576 else {
                    process.terminate()
                    process.waitUntilExit()
                    return []
                }
                bytes.append(chunk)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0, let text = String(data: bytes, encoding: .utf8) else { return [] }
            return Set(text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") })
        } catch {
            return []
        }
    }

    private func openAPIRoutes(_ value: PearfyMigrationJSONValue, path: String) -> [PearfyLegacyRouteContract] {
        guard case .object(let rootObject) = value,
              case .object(let pathsObject)? = rootObject["paths"] else { return [] }
        let methods: Set<String> = ["get", "post", "put", "patch", "delete", "head", "options", "trace"]
        var routes: [PearfyLegacyRouteContract] = []
        for routePath in pathsObject.keys.sorted() {
            guard case .object(let pathItem)? = pathsObject[routePath] else { continue }
            for method in pathItem.keys.filter({ methods.contains($0.lowercased()) }).sorted() {
                guard case .object(let operation)? = pathItem[method] else { continue }
                let upperMethod = method.uppercased()
                let operationID = string(operation["operationId"]) ?? Self.operationID(method: upperMethod, path: routePath)
                var responses: [String: PearfyLegacyResponseContract] = [:]
                if case .object(let responseMap)? = operation["responses"] {
                    for status in responseMap.keys.sorted() {
                        guard case .object(let response)? = responseMap[status] else { continue }
                        let content = object(response["content"])
                        let contentTypes = content.keys.sorted()
                        var schema: PearfyMigrationJSONValue?
                        var examples: [String: PearfyMigrationJSONValue] = [:]
                        for contentType in contentTypes {
                            guard case .object(let media)? = content[contentType] else { continue }
                            if schema == nil { schema = media["schema"] }
                            if let example = media["example"] { examples[contentType] = example }
                        }
                        responses[status] = PearfyLegacyResponseContract(
                            description: string(response["description"]),
                            contentTypes: contentTypes,
                            schema: schema,
                            examples: examples
                        )
                    }
                }
                var request: PearfyMigrationJSONValue?
                if case .object(let body)? = operation["requestBody"],
                   case .object(let content)? = body["content"] {
                    request = .object(content)
                }
                let parameterItems = sequence(operation["parameters"]) + sequence(pathItem["parameters"])
                let parameters = parameterItems.compactMap { item -> PearfyLegacyParameterContract? in
                    guard case .object(let values) = item,
                          let name = string(values["name"]),
                          let location = string(values["in"]) else { return nil }
                    let schema = values["schema"]
                    let schemaObject = object(schema)
                    let example = values["example"]
                        ?? schemaObject["example"]
                        ?? schemaObject["default"]
                        ?? sequence(schemaObject["enum"]).first
                    let required: Bool
                    if case .boolean(let explicit)? = values["required"] { required = explicit }
                    else { required = location == "path" }
                    return PearfyLegacyParameterContract(
                        name: name,
                        location: location,
                        required: required,
                        schema: schema,
                        example: example
                    )
                }
                let securityValue = operation["security"] ?? rootObject["security"]
                let security = sequence(securityValue).compactMap { value -> String? in
                    guard case .object(let schemes) = value else { return nil }
                    return schemes.keys.sorted().joined(separator: "+")
                }
                let sourceEvidence = PearfyMigrationEvidence(
                    source: "openapi",
                    path: path,
                    confidence: .high,
                    detail: "Operation \(operationID)"
                )
                routes.append(PearfyLegacyRouteContract(
                    id: operationID,
                    method: upperMethod,
                    path: routePath,
                    parameters: parameters,
                    request: request,
                    responses: responses,
                    security: security,
                    evidence: [sourceEvidence],
                    state: .contracted
                ))
            }
        }
        return routes
    }

    private func openAPIComponents(_ value: PearfyMigrationJSONValue) -> [String: PearfyMigrationJSONValue] {
        guard case .object(let root) = value else { return [:] }
        if case .object(let components)? = root["components"], case .object(let schemas)? = components["schemas"] { return schemas }
        if case .object(let definitions)? = root["definitions"] { return definitions }
        return [:]
    }

    private func isPostmanCollection(path: String, text: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "json"
            && (URL(fileURLWithPath: path).lastPathComponent.lowercased().contains("postman")
                || text.contains("postman.com/json/collection"))
            && text.contains("\"item\"")
    }

    private func postmanRoutes(_ document: PearfyMigrationJSONValue, path: String) -> [PearfyLegacyRouteContract] {
        guard case .object(let root) = document else { return [] }
        var routes: [PearfyLegacyRouteContract] = []

        func visit(_ items: [PearfyMigrationJSONValue]) {
            for item in items {
                guard case .object(let values) = item else { continue }
                if let requestValue = values["request"], case .object(let request) = requestValue,
                   let rawMethod = string(request["method"]) {
                    let method = rawMethod.uppercased()
                    guard ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(method),
                          let pathValue = postmanPath(request["url"]) else { continue }
                    let normalizedPath = normalizePostmanPath(pathValue)
                    guard normalizedPath.hasPrefix("/") else { continue }
                    let urlObject = object(request["url"])
                    let pathNames = regexMatches(#"\{([^}]+)\}"#, in: normalizedPath).compactMap { $0.count > 1 ? $0[1] : nil }
                    var parameters = pathNames.map { name in
                        PearfyLegacyParameterContract(
                            name: name,
                            location: "path",
                            required: true,
                            example: nil
                        )
                    }
                    if case .array(let queryItems)? = urlObject["query"] {
                        for query in queryItems {
                            let queryObject = object(query)
                            guard let name = string(queryObject["key"]), !name.isEmpty else { continue }
                            if case .boolean(true)? = queryObject["disabled"] { continue }
                            parameters.append(PearfyLegacyParameterContract(name: name, location: "query", required: false))
                        }
                    }
                    var headers: [String: String] = [:]
                    if case .array(let headerItems)? = request["header"] {
                        for header in headerItems {
                            let headerObject = object(header)
                            guard let name = string(headerObject["key"]), name.lowercased() == "content-type",
                                  let value = string(headerObject["value"]) else { continue }
                            headers[name.lowercased()] = value
                        }
                    }
                    let requestBody = postmanRequestShape(request["body"], headers: headers)
                    var responses: [String: PearfyLegacyResponseContract] = [:]
                    if case .array(let responseItems)? = values["response"] {
                        for response in responseItems {
                            let responseObject = object(response)
                            guard let statusValue = responseObject["code"],
                                  let status = scalarText(statusValue), status.allSatisfy(\.isNumber) else { continue }
                            let responseType = postmanContentType(responseObject["header"]) ?? "application/json"
                            let responseSchema = postmanResponseShape(responseObject["body"])
                            responses[status] = PearfyLegacyResponseContract(
                                description: string(responseObject["name"]),
                                contentTypes: [responseType],
                                schema: responseSchema
                            )
                        }
                    }
                    let evidence = PearfyMigrationEvidence(
                        source: "postman",
                        path: path,
                        confidence: .medium,
                        detail: "Postman request method/path; headers, cookies, auth and example values are omitted"
                    )
                    routes.append(PearfyLegacyRouteContract(
                        id: Self.operationID(method: method, path: normalizedPath),
                        method: method,
                        path: normalizedPath,
                        parameters: parameters,
                        request: requestBody,
                        responses: responses,
                        evidence: [evidence],
                        state: .contracted
                    ))
                }
                if case .array(let children)? = values["item"] { visit(children) }
            }
        }
        if case .array(let items)? = root["item"] { visit(items) }
        return routes
    }

    private func postmanPath(_ value: PearfyMigrationJSONValue?) -> String? {
        if case .string(let raw)? = value {
            guard let components = URLComponents(string: raw) else { return raw.split(separator: "?", maxSplits: 1).first.map(String.init) }
            return components.path.isEmpty ? "/" : components.path
        }
        let values = object(value)
        if case .array(let components)? = values["path"] {
            let segments = components.compactMap(scalarText).map { segment -> String in
                let stripped = segment.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if stripped.hasPrefix(":") { return "{\(stripped.dropFirst())}" }
                if stripped.hasPrefix("{{"), stripped.hasSuffix("}}") { return "{\(stripped.dropFirst(2).dropLast(2))}" }
                return stripped
            }
            return "/" + segments.filter { !$0.isEmpty }.joined(separator: "/")
        }
        if let raw = string(values["raw"]) { return postmanPath(.string(raw)) }
        return nil
    }

    private func normalizePostmanPath(_ path: String) -> String {
        let colonNormalized = path.replacingOccurrences(of: #":([A-Za-z_][A-Za-z0-9_]*)"#, with: "{$1}", options: .regularExpression)
        return colonNormalized.replacingOccurrences(of: #"\{\{([^}]+)\}\}"#, with: "{$1}", options: .regularExpression)
    }

    private func postmanRequestShape(_ body: PearfyMigrationJSONValue?, headers: [String: String]) -> PearfyMigrationJSONValue? {
        guard let body, case .object(let bodyObject) = body,
              let raw = string(bodyObject["raw"]),
              let rawData = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: rawData, options: [.fragmentsAllowed]) else { return nil }
        let type = headers["content-type"] ?? "application/json"
        return .object([type: .object(["schema": schemaShape(json)])])
    }

    private func postmanResponseShape(_ rawValue: PearfyMigrationJSONValue?) -> PearfyMigrationJSONValue? {
        guard let raw = string(rawValue), let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return schemaShape(json)
    }

    private func schemaShape(_ value: Any) -> PearfyMigrationJSONValue {
        if let object = value as? [String: Any] {
            return .object([
                "type": .string("object"),
                "properties": .object(object.mapValues(schemaShape))
            ])
        }
        if let array = value as? [Any] {
            return .object(["type": .string("array"), "items": array.first.map(schemaShape) ?? .object([:])])
        }
        if value is NSNull { return .object(["type": .string("null")]) }
        if value is String { return .object(["type": .string("string")]) }
        if let number = value as? NSNumber {
            return .object(["type": .string(CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : (String(cString: number.objCType).contains("d") ? "number" : "integer"))])
        }
        return .object(["type": .string("string")])
    }

    private func postmanContentType(_ headers: PearfyMigrationJSONValue?) -> String? {
        guard case .array(let values)? = headers else { return nil }
        for header in values {
            let object = self.object(header)
            if string(object["key"])?.lowercased() == "content-type" { return string(object["value"]) }
        }
        return nil
    }

    private func scalarText(_ value: PearfyMigrationJSONValue) -> String? {
        switch value {
        case .string(let text): text
        case .integer(let number): String(number)
        case .number(let number): String(number)
        default: nil
        }
    }

    private func sqlTableElements(in text: String, path: String) -> [PearfyLegacyElementContract] {
        let pattern = #"\b(?:CREATE|ALTER)\s+TABLE\s+(?:IF\s+(?:NOT\s+)?EXISTS\s+)?(?:[\"`]?([A-Za-z_][A-Za-z0-9_$]*)[\"`]?\.)?[\"`]?([A-Za-z_][A-Za-z0-9_$]*)[\"`]?"#
        return regexMatches(pattern, in: text).compactMap { match in
            guard match.count >= 3, !match[2].isEmpty else { return nil }
            let schema = match[1]
            let table = match[2]
            let fullName = schema.isEmpty ? table : "\(schema).\(table)"
            return PearfyLegacyElementContract(
                id: "model:sql:\(fullName)",
                kind: .model,
                name: fullName,
                attributes: ["source": .string("sql-ddl"), "artifact": .string(path)],
                evidence: [PearfyMigrationEvidence(source: "sql-schema", path: path, confidence: .medium, detail: "SQL CREATE/ALTER TABLE target")]
            )
        }
    }

    private func liquibaseTableElements(in text: String, path: String) -> [PearfyLegacyElementContract] {
        let pattern = #"<createTable\b[^>]*\btableName\s*=\s*[\"']([^\"']+)[\"']"#
        return regexMatches(pattern, in: text).compactMap { match in
            guard match.count > 1, !match[1].isEmpty else { return nil }
            let table = match[1]
            return PearfyLegacyElementContract(
                id: "model:liquibase:\(table)",
                kind: .model,
                name: table,
                attributes: ["source": .string("liquibase"), "artifact": .string(path)],
                evidence: [PearfyMigrationEvidence(source: "liquibase-schema", path: path, confidence: .medium, detail: "Liquibase createTable target")]
            )
        }
    }

    private func springRoutes(in text: String, path: String) -> [PearfyLegacyRouteContract] {
        guard text.contains("@") else { return [] }
        let classPrefix = annotationPath("RequestMapping", in: text, before: firstTypeDeclaration(in: text)) ?? ""
        let controllerName = text.contains("@RestController") || text.contains("@Controller")
            ? declaredTypeName(in: text)
            : nil
        let annotationMethods: [String: String] = [
            "GetMapping": "GET", "PostMapping": "POST", "PutMapping": "PUT",
            "PatchMapping": "PATCH", "DeleteMapping": "DELETE"
        ]
        var routes: [PearfyLegacyRouteContract] = []
        for (annotation, method) in annotationMethods {
            for (arguments, location) in annotationMatches(annotation, in: text) {
                let methodName = methodName(after: location, in: text) ?? Self.operationID(method: method, path: "")
                let paths = annotationPaths(arguments)
                let declaredPaths = paths.isEmpty ? [""] : paths
                for routePath in declaredPaths {
                    let fullPath = Self.joinPath(classPrefix, routePath)
                    let evidence = PearfyMigrationEvidence(
                        source: "spring-source",
                        path: path,
                        confidence: .medium,
                        detail: "@\(annotation) declaration \(methodName)"
                    )
                    routes.append(PearfyLegacyRouteContract(
                        id: Self.operationID(method: method, path: fullPath, preferred: methodName),
                        method: method,
                        path: fullPath.isEmpty ? "/" : fullPath,
                        implementation: controllerName.map { ["controller": $0] } ?? [:],
                        evidence: [evidence]
                    ))
                }
            }
        }
        for (arguments, location) in annotationMatches("RequestMapping", in: text) {
            guard let method = requestMappingMethod(arguments) else { continue }
            if location < firstTypeDeclaration(in: text) { continue }
            let methodName = methodName(after: location, in: text) ?? method.lowercased()
            let paths = annotationPaths(arguments)
            for routePath in (paths.isEmpty ? [""] : paths) {
                let fullPath = Self.joinPath(classPrefix, routePath)
                routes.append(PearfyLegacyRouteContract(
                    id: Self.operationID(method: method, path: fullPath, preferred: methodName),
                    method: method,
                    path: fullPath.isEmpty ? "/" : fullPath,
                    implementation: controllerName.map { ["controller": $0] } ?? [:],
                    evidence: [PearfyMigrationEvidence(source: "spring-source", path: path, confidence: .medium, detail: "@RequestMapping \(methodName)")]
                ))
            }
        }
        return routes
    }

    private func springElements(in text: String, path: String) -> [PearfyLegacyElementContract] {
        let typeAnnotations: [(String, PearfyLegacyElementKind)] = [
            ("RestController", .controller), ("Controller", .controller), ("Service", .service),
            ("Repository", .repository), ("Entity", .model), ("Component", .service)
        ]
        let methodAnnotations: [(String, PearfyLegacyElementKind)] = [
            ("Transactional", .transaction), ("PreAuthorize", .securityRule),
            ("PostAuthorize", .securityRule), ("Secured", .securityRule),
            ("RolesAllowed", .securityRule), ("Scheduled", .job),
            ("KafkaListener", .event), ("RabbitListener", .event), ("JmsListener", .event),
            ("EventListener", .event), ("Valid", .validation), ("Validated", .validation),
            ("NotNull", .validation), ("NotBlank", .validation), ("Size", .validation),
            ("Email", .validation), ("Pattern", .validation), ("Min", .validation), ("Max", .validation)
        ]
        var elements: [PearfyLegacyElementContract] = []
        for (annotation, kind) in typeAnnotations {
            for (arguments, location) in annotationMatches(annotation, in: text) {
                guard let name = declaredTypeName(after: location, in: text) else { continue }
                var attributes: [String: PearfyMigrationJSONValue] = ["annotation": .string(annotation)]
                if !arguments.isEmpty { attributes["annotationArguments"] = .string(String(arguments.prefix(256))) }
                elements.append(PearfyLegacyElementContract(
                    id: "\(kind.rawValue):\(path):\(name)",
                    kind: kind,
                    name: name,
                    attributes: attributes,
                    evidence: [PearfyMigrationEvidence(source: "spring-source", path: path, confidence: .medium, detail: "@\(annotation) type declaration")]
                ))
            }
        }
        for (annotation, kind) in methodAnnotations {
            for (arguments, location) in annotationMatches(annotation, in: text) {
                let name = methodName(after: location, in: text) ?? declaredTypeName(after: location, in: text) ?? annotation.lowercased()
                var attributes: [String: PearfyMigrationJSONValue] = ["annotation": .string(annotation)]
                if !arguments.isEmpty { attributes["annotationArguments"] = .string(String(arguments.prefix(256))) }
                let detail: String
                switch kind {
                case .transaction: detail = "Spring transaction boundary"
                case .securityRule: detail = "Spring authorization annotation"
                case .job: detail = "Spring scheduled job annotation"
                case .event: detail = "Spring event/message listener annotation"
                case .validation: detail = "Spring validation annotation"
                default: detail = "Spring semantic element"
                }
                elements.append(PearfyLegacyElementContract(
                    id: "\(kind.rawValue):\(path):\(name):\(annotation)",
                    kind: kind,
                    name: name,
                    attributes: attributes,
                    evidence: [PearfyMigrationEvidence(source: "spring-source", path: path, confidence: .medium, detail: detail)]
                ))
            }
        }
        return elements
    }

    private func declaredTypeName(in text: String) -> String? {
        regexMatches(#"\b(?:class|record|interface|enum)\s+(\w+)"#, in: text).first.flatMap { $0.count > 1 ? $0[1] : nil }
    }

    private func declaredTypeName(after location: Int, in text: String) -> String? {
        let index = String.Index(utf16Offset: min(location, text.utf16.count), in: text)
        return declaredTypeName(in: String(text[index...].prefix(2_048)))
    }

    private func nodeRoutes(in text: String, path: String) -> [PearfyLegacyRouteContract] {
        let pattern = #"(?:app|router|server)\s*\.\s*(get|post|put|patch|delete|head|options)\s*\(\s*['\"]([^'\"]+)['\"]"#
        return regexMatches(pattern, in: text).compactMap { groups in
            guard groups.count >= 3 else { return nil }
            let method = groups[1].uppercased()
            let routePath = groups[2]
            return PearfyLegacyRouteContract(
                id: Self.operationID(method: method, path: routePath),
                method: method,
                path: routePath,
                evidence: [PearfyMigrationEvidence(source: "generic-nodejs", path: path, confidence: .medium, detail: "HTTP handler registration")]
            )
        }
    }

    private func phpRoutes(in text: String, path: String) -> [PearfyLegacyRouteContract] {
        let methodPattern = #"REQUEST_METHOD['\"]?\s*\]\s*={1,3}\s*['\"](GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)['\"]"#
        let pathPattern = #"REQUEST_URI['\"]?\s*\]\s*={1,3}\s*['\"]([^'\"]+)['\"]"#
        let methods = regexMatches(methodPattern, in: text).compactMap { $0.count > 1 ? $0[1] : nil }
        let paths = regexMatches(pathPattern, in: text).compactMap { $0.count > 1 ? $0[1] : nil }
        guard methods.count == 1, paths.count == 1 else { return [] }
        return [PearfyLegacyRouteContract(
            id: Self.operationID(method: methods[0], path: paths[0]),
            method: methods[0],
            path: paths[0],
            evidence: [PearfyMigrationEvidence(source: "generic-php", path: path, confidence: .low, detail: "request method and URI comparisons")]
        )]
    }

    private func nestRoutes(in text: String, path: String) -> [PearfyLegacyRouteContract] {
        let classPrefix = annotationPath("Controller", in: text, before: firstTypeDeclaration(in: text), allowRelative: true) ?? ""
        let controller = declaredTypeName(in: text)
        let methods: [String: String] = ["Get": "GET", "Post": "POST", "Put": "PUT", "Patch": "PATCH", "Delete": "DELETE"]
        var routes: [PearfyLegacyRouteContract] = []
        for (annotation, method) in methods {
            for (arguments, location) in annotationMatches(annotation, in: text) {
                let methodName = methodName(after: location, in: text) ?? method.lowercased()
                let suffix = normalizePostmanPath(annotationPaths(arguments, allowRelative: true).first ?? "")
                let fullPath = Self.joinPath(classPrefix, suffix)
                routes.append(PearfyLegacyRouteContract(
                    id: Self.operationID(method: method, path: fullPath, preferred: methodName),
                    method: method,
                    path: fullPath.isEmpty ? "/" : fullPath,
                    implementation: controller.map { ["controller": $0] } ?? [:],
                    evidence: [PearfyMigrationEvidence(source: "nestjs-source", path: path, confidence: .medium, detail: "NestJS @\(annotation) handler")]
                ))
            }
        }
        return routes
    }

    private func fastAPIRoutes(in text: String, path: String) -> [PearfyLegacyRouteContract] {
        let pattern = #"@(?:app|router)\.(get|post|put|patch|delete|head|options)\s*\(\s*['\"]([^'\"]+)['\"]"#
        return regexMatches(pattern, in: text).compactMap { groups in
            guard groups.count >= 3 else { return nil }
            let method = groups[1].uppercased()
            let routePath = normalizePostmanPath(groups[2])
            return PearfyLegacyRouteContract(
                id: Self.operationID(method: method, path: routePath),
                method: method,
                path: routePath,
                evidence: [PearfyMigrationEvidence(source: "fastapi-source", path: path, confidence: .medium, detail: "FastAPI route decorator")]
            )
        }
    }

    private func laravelRoutes(in text: String, path: String) -> [PearfyLegacyRouteContract] {
        let pattern = #"Route\s*::\s*(get|post|put|patch|delete|options|any)\s*\(\s*['\"]([^'\"]+)['\"]"#
        var routes: [PearfyLegacyRouteContract] = []
        for groups in regexMatches(pattern, in: text) where groups.count >= 3 {
            let method = groups[1].uppercased() == "ANY" ? "GET" : groups[1].uppercased()
            let pathValue = normalizePostmanPath(groups[2])
            let routePath = pathValue.hasPrefix("/") ? pathValue : "/" + pathValue
            let declaredMethod = groups[1].uppercased()
            let methods = declaredMethod == "ANY" ? ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"] : [method]
            for verb in methods {
                routes.append(PearfyLegacyRouteContract(
                    id: Self.operationID(method: verb, path: routePath),
                    method: verb,
                    path: routePath,
                    evidence: [PearfyMigrationEvidence(source: "laravel-source", path: path, confidence: .medium, detail: "Laravel Route::\(groups[1].lowercased()) declaration")]
                ))
            }
        }
        return routes
    }

    private func aspNetRoutes(in text: String, path: String) -> [PearfyLegacyRouteContract] {
        let className = declaredTypeName(in: text)
        let classToken = className?.hasSuffix("Controller") == true
            ? String(className!.dropLast("Controller".count))
            : (className ?? "")
        let typeBoundary = firstTypeDeclaration(in: text)
        let routePattern = #"\[\s*Route\s*\(\s*['\"]([^'\"]+)['\"]"#
        let routeAttribute = regexMatchesCapturesWithRanges(routePattern, in: text)
            .first(where: { $0.1 < typeBoundary })?.0.first ?? ""
        let prefix = routeAttribute.replacingOccurrences(of: "[controller]", with: classToken, options: .caseInsensitive)
        let pattern = #"\[\s*Http(Get|Post|Put|Patch|Delete|Head|Options)(?:\s*\(\s*['\"]([^'\"]*)['\"]\s*\))?\s*\]"#
        var routes: [PearfyLegacyRouteContract] = []
        for (groups, location) in regexMatchesCapturesWithRanges(pattern, in: text) {
            guard let action = groups.first else { continue }
            let method = action.uppercased()
            let suffix = groups.count > 1 ? groups[1] : ""
            let fullPath = Self.joinPath(prefix, suffix)
            let actionName = methodName(after: location, in: text) ?? method.lowercased()
            routes.append(PearfyLegacyRouteContract(
                id: Self.operationID(method: method, path: fullPath, preferred: actionName),
                method: method,
                path: fullPath.isEmpty ? "/" : fullPath,
                implementation: className.map { ["controller": $0] } ?? [:],
                evidence: [PearfyMigrationEvidence(source: "aspnet-source", path: path, confidence: .medium, detail: "ASP.NET Core HTTP verb attribute")]
            ))
        }
        return routes
    }

    private func aspNetSecurityElements(in text: String, path: String) -> [PearfyLegacyElementContract] {
        let pattern = #"\[\s*(Authorize|AllowAnonymous)(?:\s*\(([^)]*)\))?\s*\]"#
        return regexMatchesCapturesWithRanges(pattern, in: text).compactMap { groups, location in
            guard let annotation = groups.first else { return nil }
            let name = methodName(after: location, in: text) ?? declaredTypeName(after: location, in: text) ?? "controller"
            let args = groups.count > 1 ? groups[1] : ""
            var attributes: [String: PearfyMigrationJSONValue] = ["annotation": .string(annotation)]
            if !args.isEmpty { attributes["policyMetadata"] = .string(String(args.prefix(256))) }
            return PearfyLegacyElementContract(
                id: "security-rule:\(path):\(name):\(annotation)",
                kind: .securityRule,
                name: name,
                attributes: attributes,
                evidence: [PearfyMigrationEvidence(source: "aspnet-source", path: path, confidence: .medium, detail: "ASP.NET Core authorization attribute")]
            )
        }
    }

    private func goRoutes(in text: String, path: String) -> [PearfyLegacyRouteContract] {
        let pattern = #"\b\w+\s*\.\s*(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s*\(\s*['\"]([^'\"]+)['\"]"#
        return regexMatches(pattern, in: text).compactMap { groups in
            guard groups.count >= 3 else { return nil }
            let method = groups[1].uppercased()
            let pathValue = normalizePostmanPath(groups[2])
            let routePath = pathValue.hasPrefix("/") ? pathValue : "/" + pathValue
            return PearfyLegacyRouteContract(
                id: Self.operationID(method: method, path: routePath),
                method: method,
                path: routePath,
                evidence: [PearfyMigrationEvidence(source: "generic-go", path: path, confidence: .low, detail: "Go router method/path registration")]
            )
        }
    }

    private func merge(_ discovered: PearfyLegacyRouteContract, into routes: inout [String: PearfyLegacyRouteContract]) {
        guard var existing = routes[discovered.key] else {
            routes[discovered.key] = discovered
            return
        }
        if existing.id != discovered.id {
            existing.conflicts.append(PearfyMigrationConflict(field: "operationId", candidates: [existing.id, discovered.id].sorted(), evidence: existing.evidence + discovered.evidence))
        }
        if let request = discovered.request {
            if let oldRequest = existing.request, oldRequest != request {
                existing.conflicts.append(PearfyMigrationConflict(field: "request", candidates: ["contract-a", "contract-b"], evidence: existing.evidence + discovered.evidence))
            } else if existing.request == nil { existing.request = request }
        }
        if existing.parameters.isEmpty { existing.parameters = discovered.parameters }
        else if !discovered.parameters.isEmpty, existing.parameters != discovered.parameters {
            existing.conflicts.append(PearfyMigrationConflict(
                field: "parameters",
                candidates: ["parameter-set-a", "parameter-set-b"],
                evidence: existing.evidence + discovered.evidence
            ))
        }
        for (status, response) in discovered.responses {
            if let old = existing.responses[status], old != response {
                existing.conflicts.append(PearfyMigrationConflict(field: "responses.\(status)", candidates: ["contract-a", "contract-b"], evidence: existing.evidence + discovered.evidence))
            } else {
                existing.responses[status] = response
            }
        }
        existing.security = Array(Set(existing.security + discovered.security)).sorted()
        existing.evidence = Array(Set(existing.evidence + discovered.evidence)).sorted {
            ($0.source, $0.path ?? "", $0.detail) < ($1.source, $1.path ?? "", $1.detail)
        }
        if !existing.conflicts.isEmpty { existing.state = .conflict }
        else if existing.state == .discovered && discovered.state == .contracted { existing.state = .contracted }
        routes[discovered.key] = existing
    }

    private func merge(_ discovered: PearfyLegacyElementContract, into elements: inout [String: PearfyLegacyElementContract]) {
        guard var existing = elements[discovered.id] else {
            elements[discovered.id] = discovered
            return
        }
        for (key, value) in discovered.attributes {
            if let old = existing.attributes[key], old != value {
                existing.conflicts.append(PearfyMigrationConflict(
                    field: "attributes.\(key)",
                    candidates: ["evidence-a", "evidence-b"],
                    evidence: existing.evidence + discovered.evidence
                ))
            } else {
                existing.attributes[key] = value
            }
        }
        existing.evidence = Array(Set(existing.evidence + discovered.evidence)).sorted {
            ($0.source, $0.path ?? "", $0.detail) < ($1.source, $1.path ?? "", $1.detail)
        }
        existing.conflicts = Array(Set(existing.conflicts + discovered.conflicts)).sorted { $0.field < $1.field }
        if !existing.conflicts.isEmpty { existing.state = .conflict }
        elements[discovered.id] = existing
    }

    private func annotationPath(_ name: String, in text: String, before boundary: Int, allowRelative: Bool = false) -> String? {
        annotationMatches(name, in: text).first(where: { $0.1 < boundary }).flatMap { annotationPaths($0.0, allowRelative: allowRelative).first }
    }

    private func annotationMatches(_ name: String, in text: String) -> [(String, Int)] {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "@\(escaped)(?![A-Za-z0-9_])\\s*(?:\\(([^)]*)\\))?"
        return regexMatchesWithRanges(pattern, in: text).map { ($0.0, $0.1) }
    }

    private func annotationPaths(_ arguments: String, allowRelative: Bool = false) -> [String] {
        let quoted = regexMatches(#"['\"]([^'\"]*)['\"]"#, in: arguments).compactMap { $0.count > 1 ? $0[1] : nil }
        return Array(Set(quoted.filter { allowRelative || $0.hasPrefix("/") || $0.isEmpty })).sorted()
    }

    private func requestMappingMethod(_ arguments: String) -> String? {
        let pattern = #"RequestMethod\.(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)"#
        return regexMatches(pattern, in: arguments).first.flatMap { $0.count > 1 ? $0[1] : nil }
    }

    private func methodName(after location: Int, in text: String) -> String? {
        let tail = String(text.dropFirst(min(location, text.count)))
        let pattern = #"(?:public|protected|private|internal|static|final|suspend|open|override|\s)+[\w<>?,.\[\] ]+\s+(\w+)\s*\("#
        return regexMatches(pattern, in: tail).first.flatMap { $0.count > 1 ? $0[1] : nil }
    }

    private func firstTypeDeclaration(in text: String) -> Int {
        let pattern = #"\b(class|record|interface|enum)\s+\w+"#
        return regexRanges(pattern, in: text).first?.location ?? text.count
    }

    private func regexMatchesCapturesWithRanges(_ pattern: String, in text: String) -> [([String], Int)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            let captures = (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            return (captures, match.range.location)
        }
    }

    private func regexMatches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: text) else { return "" }
                return String(text[range])
            }
        }
    }

    private func regexMatchesWithRanges(_ pattern: String, in text: String) -> [(String, Int)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            let value = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
            return (value, match.range.location)
        }
    }

    private func regexRanges(_ pattern: String, in text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }

    private func isOpenAPIDocument(path: String, text: String) -> Bool {
        isOpenAPIPotentialPath(path) && (text.contains("\"paths\"") || text.contains("paths:") || text.contains("openapi:") || text.contains("swagger:"))
    }

    private func isOpenAPIPotentialPath(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["json", "yaml", "yml"].contains(ext)
            && (name.contains("openapi") || name.contains("swagger") || name == "api.json" || name == "api.yml" || name == "api.yaml")
    }

    private func isAnalyzableTextExtension(_ ext: String) -> Bool {
        ["java", "kt", "js", "jsx", "ts", "tsx", "php", "py", "go", "cs", "csproj", "swift", "json", "yaml", "yml", "xml", "properties", "toml", "txt", "md", "sql"].contains(ext)
    }

    private func language(for ext: String) -> String? {
        switch ext {
        case "java": "java"
        case "kt": "kotlin"
        case "js", "jsx": "javascript"
        case "ts", "tsx": "typescript"
        case "php": "php"
        case "py": "python"
        case "go": "go"
        case "cs": "csharp"
        case "csproj": "csharp"
        case "swift": "swift"
        default: nil
        }
    }

    private func relative(_ url: URL, to root: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    private func string(_ value: PearfyMigrationJSONValue?) -> String? {
        guard case .string(let result)? = value else { return nil }
        return result
    }

    private func object(_ value: PearfyMigrationJSONValue?) -> [String: PearfyMigrationJSONValue] {
        guard case .object(let result)? = value else { return [:] }
        return result
    }

    private func sequence(_ value: PearfyMigrationJSONValue?) -> [PearfyMigrationJSONValue] {
        guard case .array(let result)? = value else { return [] }
        return result
    }

    private static func operationID(method: String, path: String, preferred: String? = nil) -> String {
        if let preferred, !preferred.isEmpty { return preferred }
        let slug = path.split(separator: "/").map { component in
            component.hasPrefix("{") && component.hasSuffix("}") ? "by-" + component.dropFirst().dropLast() : String(component)
        }.joined(separator: ".")
        return "\(method.lowercased()).\(slug.isEmpty ? "root" : slug)"
    }

    private static func joinPath(_ prefix: String, _ suffix: String) -> String {
        let parts = [prefix, suffix].filter { !$0.isEmpty }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return "/" + parts.filter { !$0.isEmpty }.joined(separator: "/")
    }
}

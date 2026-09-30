import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PearfyMigrationE2EResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case verified, mismatch }

    public let schemaVersion: Int
    public let route: String
    public let outcome: Outcome
    public let legacyStatus: Int
    public let pearfyStatus: Int
    public let mismatches: [String]
    public let comparedResponseBytes: Int
    public let elapsedMilliseconds: Int64
    public let recordedAt: String

    public var matches: Bool { outcome == .verified }
}

enum MigrationHTTPComparisonError: Error, Sendable, Equatable {
    case incomplete(String)
    case responseTooLarge
    case invalidResponse
    case transportFailed
}

enum MigrationHTTPComparison {
    struct BaseURLs {
        let legacy: URL
        let pearfy: URL
    }

    private struct Settings: Decodable {
        struct Comparison: Decodable {
            struct Timestamps: Decodable { let normalize: Bool? }
            let bodyIgnore: [String]?
            let timestamps: Timestamps?
            let arrays: [String: ArrayRule]?
            let headers: [String]?
            enum CodingKeys: String, CodingKey {
                case bodyIgnore = "ignore"
                case timestamps
                case arrays
                case headers
            }
        }
        struct ArrayRule: Decodable { let order: String? }
        let comparison: Comparison?
    }

    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    typealias HTTPResponder = @Sendable (URLRequest) async throws -> Response

    static func baseURLs(environment: [String: String]) throws -> BaseURLs {
        guard let legacyText = environment["PEARFY_LEGACY_URL"],
              let pearfyText = environment["PEARFY_URL"] else {
            throw MigrationHTTPComparisonError.incomplete("set PEARFY_LEGACY_URL and PEARFY_URL")
        }
        let legacy = try validateBaseURL(legacyText, environment: environment)
        let pearfy = try validateBaseURL(pearfyText, environment: environment)
        return BaseURLs(legacy: legacy, pearfy: pearfy)
    }

    static func compare(
        route: PearfyLegacyRouteContract,
        baseURLs: BaseURLs,
        environment: [String: String],
        allowWrites: Bool,
        responder: HTTPResponder? = nil
    ) async throws -> PearfyMigrationE2EResult {
        guard route.state == .implemented || route.state == .e2eGenerated else {
            throw MigrationHTTPComparisonError.incomplete("mark the route implemented before E2E verification")
        }
        let method = route.method.uppercased()
        if !["GET", "HEAD", "OPTIONS"].contains(method) {
            guard allowWrites, environment["PEARFY_MIGRATION_SANDBOX"] == "1" else {
                throw MigrationHTTPComparisonError.incomplete("write routes require --allow-writes and PEARFY_MIGRATION_SANDBOX=1")
            }
            guard isLoopback(baseURLs.legacy.host) && isLoopback(baseURLs.pearfy.host)
                    || environment["PEARFY_MIGRATION_ALLOW_REMOTE"] == "1" else {
                throw MigrationHTTPComparisonError.incomplete("write routes require loopback endpoints or explicit remote-sandbox opt-in")
            }
        }
        if (!isLoopback(baseURLs.legacy.host) || !isLoopback(baseURLs.pearfy.host)),
           (baseURLs.legacy.scheme != "https" || baseURLs.pearfy.scheme != "https") {
            throw MigrationHTTPComparisonError.incomplete("remote contract endpoints must use HTTPS")
        }
        let requestParts = try makeRequestParts(route: route)
        let settings = loadSettings(environment: environment)
        let requestID = UUID().uuidString
        let started = ContinuousClock.now
        let legacyResponse = try await request(
            baseURL: baseURLs.legacy,
            route: route,
            requestParts: requestParts,
            requestID: requestID,
            authorization: environment["PEARFY_LEGACY_AUTHORIZATION"] ?? environment["PEARFY_MIGRATION_AUTHORIZATION"],
            responder: responder
        )
        let pearfyResponse = try await request(
            baseURL: baseURLs.pearfy,
            route: route,
            requestParts: requestParts,
            requestID: requestID,
            authorization: environment["PEARFY_AUTHORIZATION"] ?? environment["PEARFY_MIGRATION_AUTHORIZATION"],
            responder: responder
        )
        let elapsed = started.duration(to: .now).components
        let elapsedMilliseconds = max(0, elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
        let differences = compareResponses(legacyResponse, pearfyResponse, settings: settings)
        return PearfyMigrationE2EResult(
            schemaVersion: 1,
            route: route.key,
            outcome: differences.isEmpty ? .verified : .mismatch,
            legacyStatus: legacyResponse.status,
            pearfyStatus: pearfyResponse.status,
            mismatches: differences,
            comparedResponseBytes: legacyResponse.body.count + pearfyResponse.body.count,
            elapsedMilliseconds: Int64(elapsedMilliseconds),
            recordedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    static func writeResult(_ result: PearfyMigrationE2EResult, route: PearfyLegacyRouteContract, root: URL) throws {
        let directory = root.appendingPathComponent(".pearfy/e2e/results", isDirectory: true)
        try ensureSafeDirectory(directory, root: root)
        let file = directory.appendingPathComponent(resultFileName(route.key) + ".json")
        try ensureRegularOrMissingFile(file)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(result) + Data([0x0a])).write(to: file, options: .atomic)
    }

    static func curlSafePath(_ path: String, parameters: [PearfyLegacyParameterContract]) -> String {
        var result = path
        for parameter in parameters where parameter.location == "path" {
            let name = parameter.name.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
            result = result.replacingOccurrences(of: "{\(parameter.name)}", with: "${PEARFY_PARAM_\(name)}")
        }
        return result
    }

    static func curlSafeQueryArguments(_ parameters: [PearfyLegacyParameterContract]) -> String {
        parameters.filter { $0.location == "query" }.map { parameter in
            let name = parameter.name.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
            return "--data-urlencode \"\(parameter.name)=${PEARFY_QUERY_\(name)}\""
        }.joined(separator: " ")
    }

    private struct RequestParts {
        let path: String
        let body: Data?
        let contentType: String?
        let headers: [String: String]
    }

    private static func makeRequestParts(route: PearfyLegacyRouteContract) throws -> RequestParts {
        var path = route.path
        var query: [URLQueryItem] = []
        var headers: [String: String] = [:]
        for parameter in route.parameters {
            let example = parameter.example ?? schemaDefault(parameter.schema)
            if parameter.location == "path" {
                guard let example else {
                    throw MigrationHTTPComparisonError.incomplete("path parameter \(parameter.name) has no example/default fixture")
                }
                path = path.replacingOccurrences(of: "{\(parameter.name)}", with: encodePathSegment(scalarString(example)))
            } else if parameter.location == "query", let example {
                query.append(URLQueryItem(name: parameter.name, value: scalarString(example)))
            } else if parameter.location == "header", let example {
                let name = parameter.name.lowercased()
                if !["authorization", "cookie", "set-cookie", "proxy-authorization"].contains(name) {
                    headers[parameter.name] = scalarString(example)
                }
            } else if parameter.required && (parameter.location == "query" || parameter.location == "header") {
                if parameter.location == "header", ["authorization", "cookie", "set-cookie", "proxy-authorization"].contains(parameter.name.lowercased()) {
                    continue
                }
                throw MigrationHTTPComparisonError.incomplete("required \(parameter.location) parameter \(parameter.name) has no example/default fixture")
            }
        }
        if path.contains("{") { throw MigrationHTTPComparisonError.incomplete("route path contains an unfilled parameter") }

        var body: Data?
        var contentType: String?
        if let request = route.request, case .object(let mediaTypes) = request, !mediaTypes.isEmpty {
            for mediaType in mediaTypes.keys.sorted() {
                guard case .object(let media)? = mediaTypes[mediaType] else { continue }
                let example = media["example"] ?? firstExample(media["examples"]) ?? schemaDefault(media["schema"])
                guard let example else { continue }
                body = try encodeJSON(example)
                contentType = mediaType
                break
            }
            if body == nil && route.method != "GET" && route.method != "HEAD" {
                throw MigrationHTTPComparisonError.incomplete("request body has no explicit fixture example")
            }
        }
        if !query.isEmpty {
            var components = URLComponents()
            components.path = path
            components.queryItems = query
            path = components.string ?? path
        }
        return RequestParts(path: path, body: body, contentType: contentType, headers: headers)
    }

    private static func request(
        baseURL: URL,
        route: PearfyLegacyRouteContract,
        requestParts: RequestParts,
        requestID: String,
        authorization: String?,
        responder: HTTPResponder?
    ) async throws -> Response {
        guard let routeComponents = URLComponents(string: requestParts.path),
              var baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MigrationHTTPComparisonError.incomplete("contract route could not be encoded as a URL")
        }
        let basePath = baseComponents.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let routePath = routeComponents.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        baseComponents.path = "/" + [basePath, routePath].filter { !$0.isEmpty }.joined(separator: "/")
        baseComponents.queryItems = routeComponents.queryItems
        guard let url = baseComponents.url,
              url.scheme == baseURL.scheme,
              url.host == baseURL.host,
              url.port == baseURL.port else {
            throw MigrationHTTPComparisonError.incomplete("contract route produced a URL outside its configured base origin")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = route.method
        request.httpBody = requestParts.body
        request.httpShouldHandleCookies = false
        if let contentType = requestParts.contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (name, value) in requestParts.headers { request.setValue(value, forHTTPHeaderField: name) }
        if let authorization, !authorization.isEmpty {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.setValue(requestID, forHTTPHeaderField: "X-Pearfy-Migration-Request-ID")
        do {
            if let responder {
                let response = try await responder(request)
                guard response.body.count <= 2 * 1_024 * 1_024 else {
                    throw MigrationHTTPComparisonError.responseTooLarge
                }
                return response
            }
            return try await BoundedHTTPProbe(maximumBytes: 2 * 1_024 * 1_024).send(request)
        } catch MigrationHTTPComparisonError.responseTooLarge {
            throw MigrationHTTPComparisonError.responseTooLarge
        } catch {
            throw MigrationHTTPComparisonError.transportFailed
        }
    }

    private static func compareResponses(_ lhs: Response, _ rhs: Response, settings: Settings?) -> [String] {
        var mismatches: [String] = []
        if lhs.status != rhs.status { mismatches.append("status") }
        let configuredHeaders = settings?.comparison?.headers ?? ["content-type", "location", "allow", "cache-control"]
        for header in configuredHeaders.map({ $0.lowercased() }).sorted() {
            if (lhs.headers[header] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                != (rhs.headers[header] ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
                mismatches.append("header:\(header)")
            }
        }
        let leftValue = responseValue(lhs)
        let rightValue = responseValue(rhs)
        let ignore = settings?.comparison?.bodyIgnore ?? ["$.requestId", "$.traceId"]
        let unordered = settings?.comparison?.arrays?.filter { $0.value.order == "ignored" }.map(\.key) ?? []
        let normalizeTimestamps = settings?.comparison?.timestamps?.normalize ?? true
        if normalizeContractValue(leftValue, path: "$", ignore: ignore, unordered: unordered, normalizeTimestamps: normalizeTimestamps)
            != normalizeContractValue(rightValue, path: "$", ignore: ignore, unordered: unordered, normalizeTimestamps: normalizeTimestamps) {
            mismatches.append("body")
        }
        return mismatches
    }

    private static func loadSettings(environment: [String: String]) -> Settings? {
        let settingsURL: URL
        if let path = environment["PEARFY_MIGRATION_E2E_SETTINGS"] {
            settingsURL = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        } else {
            settingsURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".pearfy/e2e/settings.yml")
        }
        return try? PearfyMigrationDocumentStore.load(Settings.self, from: settingsURL)
    }

    private static func responseValue(_ response: Response) -> PearfyMigrationJSONValue {
        if let decoded = try? JSONDecoder().decode(PearfyMigrationJSONValue.self, from: response.body) { return decoded }
        return .string(String(decoding: response.body, as: UTF8.self))
    }

    static func normalizeContractValue(
        _ value: PearfyMigrationJSONValue,
        path: String,
        ignore: [String],
        unordered: [String],
        normalizeTimestamps: Bool
    ) -> PearfyMigrationJSONValue {
        if ignore.contains(path) { return .null }
        switch value {
        case .object(let object):
            let children = object.keys.sorted().compactMap { key -> (String, PearfyMigrationJSONValue)? in
                let childPath = "\(path).\(key)"
                guard !ignore.contains(childPath) else { return nil }
                return (key, normalizeContractValue(object[key]!, path: childPath, ignore: ignore, unordered: unordered, normalizeTimestamps: normalizeTimestamps))
            }
            return .object(Dictionary(uniqueKeysWithValues: children))
        case .array(let values):
            var values = values.enumerated().map { index, element in
                normalizeContractValue(element, path: "\(path)[\(index)]", ignore: ignore, unordered: unordered, normalizeTimestamps: normalizeTimestamps)
            }
            if unordered.contains(path) {
                values.sort { canonicalString($0) < canonicalString($1) }
            }
            return .array(values)
        case .string(let string):
            if normalizeTimestamps, isTimestamp(string) { return .string("<timestamp>") }
            return .string(string)
        default: return value
        }
    }

    private static func isTimestamp(_ value: String) -> Bool {
        value.count >= 20 && value.contains("T") && (value.hasSuffix("Z") || value.contains("+") || value.contains("-"))
            && ISO8601DateFormatter().date(from: value) != nil
    }

    private static func canonicalString(_ value: PearfyMigrationJSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func schemaDefault(_ value: PearfyMigrationJSONValue?) -> PearfyMigrationJSONValue? {
        guard case .object(let object)? = value else { return nil }
        return object["example"] ?? object["default"] ?? sequenceFirst(object["enum"])
    }

    private static func firstExample(_ value: PearfyMigrationJSONValue?) -> PearfyMigrationJSONValue? {
        guard case .object(let values)? = value,
              let first = values.keys.sorted().first,
              case .object(let example)? = values[first] else { return nil }
        return example["value"]
    }

    private static func sequenceFirst(_ value: PearfyMigrationJSONValue?) -> PearfyMigrationJSONValue? {
        guard case .array(let values)? = value else { return nil }
        return values.first
    }

    private static func scalarString(_ value: PearfyMigrationJSONValue) -> String {
        switch value {
        case .string(let value): value
        case .integer(let value): String(value)
        case .number(let value): String(value)
        case .boolean(let value): String(value)
        case .null: ""
        case .object, .array: canonicalString(value)
        }
    }

    private static func encodeJSON(_ value: PearfyMigrationJSONValue) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private static func validateBaseURL(_ raw: String, environment: [String: String]) throws -> URL {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            throw MigrationHTTPComparisonError.incomplete("configured endpoints must be HTTP(S) origins without credentials, query, or fragments")
        }
        if !isLoopback(host), scheme != "https" {
            throw MigrationHTTPComparisonError.incomplete("remote endpoints require HTTPS")
        }
        if !isLoopback(host), environment["PEARFY_MIGRATION_ALLOW_REMOTE"] != "1" {
            throw MigrationHTTPComparisonError.incomplete("remote endpoints require PEARFY_MIGRATION_ALLOW_REMOTE=1")
        }
        return url
    }

    private static func isLoopback(_ host: String?) -> Bool {
        guard let host else { return false }
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized == "localhost" || normalized == "::1" || normalized.hasPrefix("127.")
    }

    private static func encodePathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? value
    }

    private static func resultFileName(_ value: String) -> String {
        let safe = value.lowercased().map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "_"
        }
        return String(safe).split(separator: "_").filter { !$0.isEmpty }.joined(separator: "_").prefix(120).description
    }

    private static func ensureSafeDirectory(_ directory: URL, root: URL) throws {
        let normalizedRoot = root.standardizedFileURL.path
        guard directory.standardizedFileURL.path.hasPrefix(normalizedRoot + "/") else {
            throw MigrationHTTPComparisonError.incomplete("result directory is outside the project")
        }
        var cursor = root.standardizedFileURL
        let relative = String(directory.standardizedFileURL.path.dropFirst(normalizedRoot.count)).split(separator: "/")
        for component in relative {
            cursor.appendPathComponent(String(component), isDirectory: true)
            if FileManager.default.fileExists(atPath: cursor.path) {
                let values = try cursor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw MigrationHTTPComparisonError.incomplete("refusing a symbolic-link E2E result directory")
                }
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func ensureRegularOrMissingFile(_ file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MigrationHTTPComparisonError.incomplete("refusing a symbolic-link E2E result file")
        }
    }

    private final class BoundedHTTPProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let maximumBytes: Int
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Response, Error>?
        private var response: HTTPURLResponse?
        private var bytes = Data()
        private var overflow = false
        private var session: URLSession?

        init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

        func send(_ request: URLRequest) async throws -> Response {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCache = nil
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                lock.lock()
                self.continuation = continuation
                self.session = session
                lock.unlock()
                session.dataTask(with: request).resume()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock()
            self.response = response as? HTTPURLResponse
            let tooLarge = response.expectedContentLength > Int64(maximumBytes)
            overflow = tooLarge
            lock.unlock()
            completionHandler(tooLarge ? .cancel : .allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            if bytes.count + data.count > maximumBytes { overflow = true }
            let shouldCancel = overflow
            if !shouldCancel { bytes.append(data) }
            lock.unlock()
            if shouldCancel { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            let response = self.response
            let bytes = self.bytes
            let overflow = self.overflow
            let session = self.session
            self.session = nil
            lock.unlock()
            session?.finishTasksAndInvalidate()
            guard let continuation else { return }
            if overflow {
                continuation.resume(throwing: MigrationHTTPComparisonError.responseTooLarge)
            } else if error != nil {
                continuation.resume(throwing: MigrationHTTPComparisonError.transportFailed)
            } else if let response {
                let headers = Dictionary(uniqueKeysWithValues: response.allHeaderFields.compactMap { key, value -> (String, String)? in
                    guard let name = key as? String else { return nil }
                    return (name.lowercased(), String(describing: value))
                })
                continuation.resume(returning: Response(status: response.statusCode, headers: headers, body: bytes))
            } else {
                continuation.resume(throwing: MigrationHTTPComparisonError.invalidResponse)
            }
        }
    }
}

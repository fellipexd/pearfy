import Foundation

public enum HTTPMethod: Hashable, Sendable, CustomStringConvertible {
    case get
    case head
    case post
    case put
    case patch
    case delete
    case options
    case custom(String)

    public init(_ value: String) {
        switch value.uppercased() {
        case "GET": self = .get
        case "HEAD": self = .head
        case "POST": self = .post
        case "PUT": self = .put
        case "PATCH": self = .patch
        case "DELETE": self = .delete
        case "OPTIONS": self = .options
        default: self = .custom(value.uppercased())
        }
    }

    public var description: String {
        switch self {
        case .get: "GET"
        case .head: "HEAD"
        case .post: "POST"
        case .put: "PUT"
        case .patch: "PATCH"
        case .delete: "DELETE"
        case .options: "OPTIONS"
        case .custom(let value): value
        }
    }
}

public enum HTTPStatus: Int, Sendable {
    case ok = 200
    case created = 201
    case accepted = 202
    case noContent = 204
    case badRequest = 400
    case unauthorized = 401
    case forbidden = 403
    case notFound = 404
    case methodNotAllowed = 405
    case requestTimeout = 408
    case payloadTooLarge = 413
    case tooManyRequests = 429
    case internalServerError = 500
    case serviceUnavailable = 503
    case gatewayTimeout = 504
}

public enum HTTPRouteAccess: Sendable, Equatable {
    case permitAll
    case authenticated
    case roles(Set<String>)
}

public struct HTTPRequest: Sendable, Equatable {
    public static let authenticatedContextKey = "pearfy.security.authenticated"
    public static let subjectContextKey = "pearfy.security.subject"
    public static let rolesContextKey = "pearfy.security.roles"
    public static let permitAllContextKey = "pearfy.security.permitAll"
    public static let routeTemplateContextKey = "pearfy.http.routeTemplate"
    public let method: HTTPMethod
    public let path: String
    public let query: [String: [String]]
    public let headers: [String: String]
    public let body: Data
    public let pathParameters: [String: String]
    private let contextValues: [String: String]

    public init(
        method: HTTPMethod,
        target: String,
        headers: [String: String] = [:],
        body: Data = Data()
    ) throws {
        guard let components = URLComponents(string: target),
              components.path.hasPrefix("/") else {
            throw HTTPError.badRequest("Malformed request target")
        }
        let normalizedPath = components.path.isEmpty ? "/" : components.path
        let decodedSegments = normalizedPath.split(separator: "/").compactMap { $0.removingPercentEncoding }
        guard !decodedSegments.contains("."), !decodedSegments.contains("..") else {
            throw HTTPError.badRequest("Dot segments are not allowed in request paths")
        }
        var queryValues: [String: [String]] = [:]
        for item in components.queryItems ?? [] {
            queryValues[item.name, default: []].append(item.value ?? "")
        }
        self.init(
            method: method,
            path: normalizedPath,
            query: queryValues,
            headers: Self.normalizeHeaders(headers),
            body: body,
            pathParameters: [:],
            contextValues: [:]
        )
    }

    private init(
        method: HTTPMethod,
        path: String,
        query: [String: [String]],
        headers: [String: String],
        body: Data,
        pathParameters: [String: String],
        contextValues: [String: String]
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.pathParameters = pathParameters
        self.contextValues = contextValues
    }

    public func pathParameter(_ name: String) -> String? {
        pathParameters[name]
    }

    public func pathValue<Value: LosslessStringConvertible & Sendable>(
        for name: String,
        as type: Value.Type = Value.self
    ) throws -> Value {
        guard let raw = pathParameters[name], let value = Value(raw) else {
            throw HTTPError.badRequest("Invalid or missing path parameter '\(name)'")
        }
        return value
    }

    public func pathUUID(for name: String) throws -> UUID {
        guard let raw = pathParameters[name], let value = UUID(uuidString: raw) else {
            throw HTTPError.badRequest("Invalid or missing UUID path parameter '\(name)' ")
        }
        return value
    }

    public func queryValue(_ name: String) -> String? {
        query[name]?.first
    }

    public func queryParameter<Value: LosslessStringConvertible & Sendable>(
        _ name: String,
        as type: Value.Type = Value.self
    ) throws -> Value {
        guard let raw = query[name]?.first, let value = Value(raw) else {
            throw HTTPError.badRequest("Invalid or missing query parameter '\(name)' ")
        }
        return value
    }

    public func queryUUID(_ name: String) throws -> UUID {
        guard let raw = query[name]?.first, let value = UUID(uuidString: raw) else {
            throw HTTPError.badRequest("Invalid or missing UUID query parameter '\(name)' ")
        }
        return value
    }

    public func headerValue<Value: LosslessStringConvertible & Sendable>(
        _ name: String,
        as type: Value.Type = Value.self
    ) throws -> Value {
        guard let raw = headers[name.lowercased()], let value = Value(raw) else {
            throw HTTPError.badRequest("Invalid or missing header '\(name)' ")
        }
        return value
    }

    public func decodeBody<Value: Decodable>(_ type: Value.Type = Value.self) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw HTTPError.badRequest("Invalid JSON request body")
        }
    }

    func addingPathParameters(_ values: [String: String]) -> HTTPRequest {
        HTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body,
            pathParameters: values,
            contextValues: contextValues
        )
    }

    func addingHeader(_ name: String, value: String) -> HTTPRequest {
        var updatedHeaders = headers
        updatedHeaders[name.lowercased()] = value
        return HTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: updatedHeaders,
            body: body,
            pathParameters: pathParameters,
            contextValues: contextValues
        )
    }

    public func contextValue(_ key: String) -> String? { contextValues[key] }

    public func addingContextValue(_ key: String, value: String) -> HTTPRequest {
        var updated = contextValues
        updated[key] = value
        return HTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body,
            pathParameters: pathParameters,
            contextValues: updated
        )
    }

    private static func normalizeHeaders(_ headers: [String: String]) -> [String: String] {
        Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, latest in latest })
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, latest in latest })
        self.body = body
    }

    public static func text(_ value: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["content-type": "text/plain; charset=utf-8"], body: Data(value.utf8))
    }

    public static func json<Value: Encodable>(_ value: Value, status: Int = 200) throws -> HTTPResponse {
        do {
            return HTTPResponse(
                status: status,
                headers: ["content-type": "application/json; charset=utf-8"],
                body: try JSONEncoder().encode(value)
            )
        } catch {
            throw HTTPError.internalServerError
        }
    }
}

public enum HTTPError: Error, Sendable, Equatable, CustomStringConvertible {
    case badRequest(String)
    case notFound
    case methodNotAllowed([String])
    case payloadTooLarge
    case headersTooLarge
    case overloaded
    case requestTimeout
    case duplicateRoute(String)
    case invalidRoute(String)
    case routerFrozen
    case routerNotFrozen
    case internalServerError

    public var status: Int {
        switch self {
        case .badRequest: 400
        case .notFound: 404
        case .methodNotAllowed: 405
        case .payloadTooLarge: 413
        case .headersTooLarge: 431
        case .overloaded: 503
        case .requestTimeout: 504
        case .duplicateRoute, .invalidRoute: 500
        case .routerFrozen: 409
        case .routerNotFrozen, .internalServerError: 500
        }
    }

    public var description: String {
        switch self {
        case .badRequest(let message): "PEARFY_HTTP_001: \(message)"
        case .notFound: "PEARFY_HTTP_404: route not found"
        case .methodNotAllowed(let methods): "PEARFY_HTTP_405: method not allowed; allowed: \(methods.joined(separator: ", "))"
        case .payloadTooLarge: "PEARFY_HTTP_413: request body exceeds configured limit"
        case .headersTooLarge: "PEARFY_HTTP_431: request headers exceed configured limit"
        case .overloaded: "PEARFY_HTTP_503: request admission limit reached"
        case .requestTimeout: "PEARFY_HTTP_504: request deadline exceeded"
        case .duplicateRoute(let route): "PEARFY_HTTP_002: duplicate route \(route)"
        case .invalidRoute(let route): "PEARFY_HTTP_003: invalid route \(route)"
        case .routerFrozen: "PEARFY_HTTP_004: routes cannot change after the router is frozen"
        case .routerNotFrozen: "PEARFY_HTTP_005: router must be frozen before serving requests"
        case .internalServerError: "PEARFY_HTTP_500: internal server error"
        }
    }

    public var response: HTTPResponse {
        let message: String
        switch self {
        case .badRequest(let detail): message = detail
        case .notFound: message = "Not Found"
        case .methodNotAllowed: message = "Method Not Allowed"
        case .payloadTooLarge: message = "Payload Too Large"
        case .headersTooLarge: message = "Request Header Fields Too Large"
        case .overloaded: message = "Service Unavailable"
        case .requestTimeout: message = "Gateway Timeout"
        case .duplicateRoute, .invalidRoute, .routerFrozen, .routerNotFrozen, .internalServerError:
            message = "Internal Server Error"
        }
        var headers: [String: String] = ["content-type": "text/plain; charset=utf-8"]
        if case .methodNotAllowed(let methods) = self {
            headers["allow"] = methods.joined(separator: ", ")
        }
        return HTTPResponse(status: status, headers: headers, body: Data(message.utf8))
    }
}

public typealias HTTPRouteHandler = @Sendable (HTTPRequest) async throws -> HTTPResponse
public typealias HTTPMiddleware = @Sendable (HTTPRequest, @Sendable (HTTPRequest) async -> HTTPResponse) async -> HTTPResponse

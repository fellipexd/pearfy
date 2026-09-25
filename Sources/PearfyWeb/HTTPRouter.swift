import Foundation

public actor HTTPRouter {
    private enum DispatchOutcome: Sendable {
        case response(HTTPResponse)
        case timeout
    }

    private enum Segment: Sendable {
        case literal(String)
        case parameter(String)
    }

    private struct Route: Sendable {
        let method: HTTPMethod
        let path: String
        let canonicalPath: String
        let segments: [Segment]
        let literalCount: Int
        let group: String?
        let requestTypeName: String?
        let responseTypeName: String?
        let access: HTTPRouteAccess
        let handler: HTTPRouteHandler
    }

    private let maximumBodyBytes: Int
    private let maximumHeaderBytes: Int
    private let maximumInFlightRequests: Int?
    private let requestDeadline: Duration?
    private var routes: [Route] = []
    private var groupsByName: [String: HTTPRouteGroup] = [:]
    private var routeKeys: Set<String> = []
    private var middleware: [HTTPMiddleware] = []
    private var frozen = false
    private var inFlightRequests = 0

    public init(
        maximumBodyBytes: Int = 1_048_576,
        maximumHeaderBytes: Int = 65_536,
        maximumInFlightRequests: Int? = nil,
        requestDeadline: Duration? = nil
    ) {
        self.maximumBodyBytes = max(0, maximumBodyBytes)
        self.maximumHeaderBytes = max(0, maximumHeaderBytes)
        self.maximumInFlightRequests = maximumInFlightRequests.map { max(0, $0) }
        self.requestDeadline = requestDeadline
    }

    public func on(
        _ method: HTTPMethod,
        path: String,
        access: HTTPRouteAccess = .permitAll,
        group: String? = nil,
        requestTypeName: String? = nil,
        responseTypeName: String? = nil,
        handler: @escaping HTTPRouteHandler
    ) throws {
        guard !frozen else { throw HTTPError.routerFrozen }
        let registeredGroup: HTTPRouteGroup?
        let registeredPath: String
        if let group {
            guard let descriptor = groupsByName[group] else {
                throw HTTPRouteGroupError.notRegistered(group)
            }
            registeredGroup = descriptor
            registeredPath = Self.joinedPath(descriptor.prefix, path)
        } else {
            registeredGroup = nil
            registeredPath = path
        }
        let parsed = try Self.parseRoute(registeredPath)
        let key = "\(method.description) \(parsed.canonical)"
        guard routeKeys.insert(key).inserted else {
            throw HTTPError.duplicateRoute("\(method) \(registeredPath)")
        }
        routes.append(Route(
            method: method,
            path: registeredPath,
            canonicalPath: parsed.canonical,
            segments: parsed.segments,
            literalCount: parsed.literalCount,
            group: registeredGroup?.name,
            requestTypeName: requestTypeName,
            responseTypeName: responseTypeName,
            access: access,
            handler: handler
        ))
        routes.sort {
            if $0.literalCount != $1.literalCount { return $0.literalCount > $1.literalCount }
            if $0.segments.count != $1.segments.count { return $0.segments.count > $1.segments.count }
            return $0.canonicalPath < $1.canonicalPath
        }
    }

    /// Registers or confirms a route group before its routes are declared.
    /// Re-registering the same descriptor is safe for controllers in separate
    /// files; changing its policy or prefix is rejected.
    public func registerGroup(_ group: HTTPRouteGroup) throws {
        guard !frozen else { throw HTTPError.routerFrozen }
        try Self.validate(group)
        if let existing = groupsByName[group.name] {
            guard existing == group else { throw HTTPRouteGroupError.conflictingDefinition(group.name) }
            return
        }
        guard !groupsByName.values.contains(where: { $0.prefix == group.prefix }) else {
            throw HTTPRouteGroupError.duplicatePrefix(group.prefix)
        }
        groupsByName[group.name] = group
    }

    public func get(
        _ path: String,
        access: HTTPRouteAccess = .permitAll,
        group: String? = nil,
        requestTypeName: String? = nil,
        responseTypeName: String? = nil,
        handler: @escaping HTTPRouteHandler
    ) throws {
        try on(
            .get,
            path: path,
            access: access,
            group: group,
            requestTypeName: requestTypeName,
            responseTypeName: responseTypeName,
            handler: handler
        )
    }

    public func post(
        _ path: String,
        access: HTTPRouteAccess = .permitAll,
        group: String? = nil,
        requestTypeName: String? = nil,
        responseTypeName: String? = nil,
        handler: @escaping HTTPRouteHandler
    ) throws {
        try on(
            .post,
            path: path,
            access: access,
            group: group,
            requestTypeName: requestTypeName,
            responseTypeName: responseTypeName,
            handler: handler
        )
    }

    public func use(_ middleware: @escaping HTTPMiddleware) throws {
        guard !frozen else { throw HTTPError.routerFrozen }
        self.middleware.append(middleware)
    }

    public func freeze() throws {
        frozen = true
    }

    public func isFrozen() -> Bool { frozen }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard frozen else { return HTTPError.routerNotFrozen.response }
        guard request.body.count <= maximumBodyBytes else { return HTTPError.payloadTooLarge.response }
        let headerBytes = request.headers.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        guard headerBytes <= maximumHeaderBytes else { return HTTPError.headersTooLarge.response }
        if let maximumInFlightRequests, inFlightRequests >= maximumInFlightRequests {
            return HTTPError.overloaded.response
        }

        inFlightRequests += 1
        defer { inFlightRequests -= 1 }
        let middlewares = middleware
        let accessContextRequest = addingRouteAccessContext(to: request)
        guard let requestDeadline else {
            return await executeMiddleware(middlewares, at: 0, request: accessContextRequest)
        }
        return await withTaskGroup(of: DispatchOutcome.self) { group in
            group.addTask { .response(await self.executeMiddleware(middlewares, at: 0, request: accessContextRequest)) }
            group.addTask {
                do {
                    try await Task.sleep(for: requestDeadline)
                    return .timeout
                } catch {
                    return .timeout
                }
            }
            let outcome = await group.next() ?? .timeout
            group.cancelAll()
            switch outcome {
            case .response(let response): return response
            case .timeout: return HTTPError.requestTimeout.response
            }
        }
    }

    public func currentInFlightRequests() -> Int { inFlightRequests }

    public func routeGroups() -> [HTTPRouteGroup] {
        groupsByName.values.sorted { $0.name < $1.name }
    }

    public func contractOperations(group: String? = nil) throws -> [HTTPRouteContractOperation] {
        if let group, groupsByName[group] == nil { throw HTTPRouteGroupError.notRegistered(group) }
        return routes
            .filter { group == nil || $0.group == group }
            .map {
                HTTPRouteContractOperation(
                    method: $0.method,
                    path: $0.path,
                    access: $0.access,
                    group: $0.group,
                    requestTypeName: $0.requestTypeName,
                    responseTypeName: $0.responseTypeName
                )
            }
            .sorted {
                if $0.path != $1.path { return $0.path < $1.path }
                return $0.method.description < $1.method.description
            }
    }

    public func openAPIDocument(title: String, version: String, group: String? = nil) throws -> Data {
        if let group, groupsByName[group] == nil { throw HTTPRouteGroupError.notRegistered(group) }
        var paths: [String: [String: Any]] = [:]
        for route in routes where group == nil || route.group == group {
            let parameters: [[String: Any]] = route.segments.compactMap { segment in
                guard case .parameter(let name) = segment else { return nil }
                return [
                    "name": name,
                    "in": "path",
                    "required": true,
                    "schema": ["type": "string"]
                ]
            }
            var operation: [String: Any] = [
                "operationId": openAPIOperationID(method: route.method, path: route.path),
                "parameters": parameters,
                "responses": ["200": ["description": "Successful response"]]
            ]
            switch route.access {
            case .permitAll:
                operation["security"] = [] as [[String: [String]]]
            case .authenticated:
                operation["security"] = [["bearerAuth": [] as [String]]]
            case .roles(let roles):
                operation["security"] = [["bearerAuth": [] as [String]]]
                operation["x-pearfy-roles"] = roles.sorted()
            }
            if let routeGroupName = route.group, let routeGroup = groupsByName[routeGroupName] {
                operation["x-pearfy-group"] = routeGroup.name
                operation["x-pearfy-contract-version"] = routeGroup.contractVersion
                operation["x-pearfy-sdk-targets"] = routeGroup.sdkTargets.map(\.rawValue).sorted()
            }
            if let requestTypeName = route.requestTypeName {
                operation["x-pearfy-request-schema"] = requestTypeName
            }
            if let responseTypeName = route.responseTypeName {
                operation["x-pearfy-response-schema"] = responseTypeName
            }
            paths[route.path, default: [:]][route.method.description.lowercased()] = operation
        }
        let document: [String: Any] = [
            "openapi": "3.1.0",
            "info": ["title": title, "version": version],
            "paths": paths,
            "components": [
                "securitySchemes": [
                    "bearerAuth": ["type": "http", "scheme": "bearer", "bearerFormat": "JWT"]
                ]
            ]
        ]
        do {
            return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        } catch {
            throw HTTPError.internalServerError
        }
    }

    private func executeMiddleware(
        _ middleware: [HTTPMiddleware],
        at index: Int,
        request: HTTPRequest
    ) async -> HTTPResponse {
        guard index < middleware.count else { return await dispatch(request) }
        let current = middleware[index]
        return await current(request) { nextRequest in
            await self.executeMiddleware(middleware, at: index + 1, request: nextRequest)
        }
    }

    private func dispatch(_ request: HTTPRequest) async -> HTTPResponse {
        var allowedMethods: Set<String> = []
        for route in routes {
            guard let parameters = Self.match(route.segments, path: request.path) else { continue }
            allowedMethods.insert(route.method.description)
            let methodMatches = route.method == request.method || (request.method == .head && route.method == .get)
            guard methodMatches else { continue }
            if let denied = authorizationFailure(for: route.access, request: request) {
                return denied
            }
            do {
                let response = try await route.handler(request.addingPathParameters(parameters))
                if request.method == .head {
                    return HTTPResponse(status: response.status, headers: response.headers, body: Data())
                }
                return response
            } catch let error as HTTPError {
                return error.response
            } catch {
                return HTTPError.internalServerError.response
            }
        }
        if !allowedMethods.isEmpty {
            if allowedMethods.contains("GET") { allowedMethods.insert("HEAD") }
            return HTTPError.methodNotAllowed(allowedMethods.sorted()).response
        }
        return HTTPError.notFound.response
    }

    private func addingRouteAccessContext(to request: HTTPRequest) -> HTTPRequest {
        for route in routes where Self.match(route.segments, path: request.path) != nil {
            let methodMatches = route.method == request.method || (request.method == .head && route.method == .get)
            guard methodMatches else { continue }
            var contextualRequest = request.addingContextValue(
                HTTPRequest.routeTemplateContextKey,
                value: route.path
            )
            if route.access == .permitAll {
                contextualRequest = contextualRequest.addingContextValue(HTTPRequest.permitAllContextKey, value: "true")
            }
            return contextualRequest
        }
        return request
    }

    private func authorizationFailure(for access: HTTPRouteAccess, request: HTTPRequest) -> HTTPResponse? {
        switch access {
        case .permitAll:
            return nil
        case .authenticated:
            guard request.contextValue(HTTPRequest.authenticatedContextKey) == "true" else {
                return HTTPResponse.text("Unauthorized", status: HTTPStatus.unauthorized.rawValue)
            }
        case .roles(let requiredRoles):
            guard request.contextValue(HTTPRequest.authenticatedContextKey) == "true" else {
                return HTTPResponse.text("Unauthorized", status: HTTPStatus.unauthorized.rawValue)
            }
            let roles = Set(request.contextValue(HTTPRequest.rolesContextKey)?.split(separator: ",").map(String.init) ?? [])
            guard !requiredRoles.isDisjoint(with: roles) else {
                return HTTPResponse.text("Forbidden", status: HTTPStatus.forbidden.rawValue)
            }
        }
        return nil
    }

    private static func parseRoute(_ path: String) throws -> (segments: [Segment], canonical: String, literalCount: Int) {
        guard path.hasPrefix("/") else { throw HTTPError.invalidRoute(path) }
        let rawSegments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var seenParameters: Set<String> = []
        var segments: [Segment] = []
        var canonicalSegments: [String] = []
        var literalCount = 0
        for segment in rawSegments {
            if segment.hasPrefix("{") || segment.hasSuffix("}") {
                guard segment.first == "{", segment.last == "}", segment.count > 2 else {
                    throw HTTPError.invalidRoute(path)
                }
                let name = String(segment.dropFirst().dropLast())
                guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                      !name.isEmpty,
                      seenParameters.insert(name).inserted else {
                    throw HTTPError.invalidRoute(path)
                }
                segments.append(.parameter(name))
                canonicalSegments.append("{}")
            } else {
                guard !segment.contains("{"), !segment.contains("}"), segment != ".", segment != ".." else {
                    throw HTTPError.invalidRoute(path)
                }
                segments.append(.literal(segment))
                canonicalSegments.append(segment)
                literalCount += 1
            }
        }
        let canonical = "/" + canonicalSegments.joined(separator: "/")
        return (segments, canonical, literalCount)
    }

    private static func validate(_ group: HTTPRouteGroup) throws {
        guard let first = group.name.utf8.first,
              (97...122).contains(first),
              group.name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
            throw HTTPRouteGroupError.invalidName(group.name)
        }
        guard group.contractVersion.split(separator: ".").count >= 2,
              group.contractVersion.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0.isLetter || $0 == "-") }) else {
            throw HTTPRouteGroupError.invalidContractVersion(group.contractVersion)
        }
        guard group.prefix.hasPrefix("/"),
              group.prefix != "/",
              !group.prefix.hasSuffix("/"),
              !group.prefix.contains("//"),
              !group.prefix.contains(where: { $0 == "?" || $0 == "#" || $0 == "%" }) else {
            throw HTTPRouteGroupError.invalidPrefix(group.prefix)
        }
        let parsed: (segments: [Segment], canonical: String, literalCount: Int)
        do {
            parsed = try parseRoute(group.prefix)
        } catch {
            throw HTTPRouteGroupError.invalidPrefix(group.prefix)
        }
        guard !parsed.segments.isEmpty,
              parsed.segments.allSatisfy({ if case .literal = $0 { true } else { false } }) else {
            throw HTTPRouteGroupError.invalidPrefix(group.prefix)
        }
    }

    private static func joinedPath(_ prefix: String, _ path: String) -> String {
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return suffix.isEmpty ? prefix : "\(prefix)/\(suffix)"
    }

    private static func match(_ pattern: [Segment], path: String) -> [String: String]? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count == pattern.count else { return nil }
        var parameters: [String: String] = [:]
        for (expected, actual) in zip(pattern, segments) {
            switch expected {
            case .literal(let literal):
                guard literal == actual else { return nil }
            case .parameter(let name):
                guard !actual.isEmpty else { return nil }
                parameters[name] = actual.removingPercentEncoding ?? actual
            }
        }
        return parameters
    }

    private func openAPIOperationID(method: HTTPMethod, path: String) -> String {
        let suffix = path.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()
        return "\(method.description.capitalized)\(suffix.isEmpty ? "Root" : suffix)"
    }
}

public extension HTTPRouter {
    static func requestID(headerName: String = "x-request-id") -> HTTPMiddleware {
        { request, next in
            let identifier = request.headers[headerName.lowercased()] ?? UUID().uuidString
            let response = await next(request.addingHeader(headerName, value: identifier))
            var headers = response.headers
            headers[headerName.lowercased()] = identifier
            return HTTPResponse(status: response.status, headers: headers, body: response.body)
        }
    }
}

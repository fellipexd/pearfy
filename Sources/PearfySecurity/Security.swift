import Crypto
import Foundation
import PearfyWeb

public struct SecurityIdentity: Sendable, Equatable {
    public let subject: String
    public let roles: Set<String>

    public init(subject: String, roles: Set<String> = []) {
        self.subject = subject
        self.roles = roles
    }
}

public struct APIKeyAuthenticator: Sendable {
    private struct Entry: Sendable {
        let key: Data
        let identity: SecurityIdentity
    }

    private let entries: [Entry]

    public init(keys: [String: SecurityIdentity]) {
        entries = keys.map { Entry(key: Data($0.key.utf8), identity: $0.value) }
    }

    public func authenticate(_ candidate: String) -> SecurityIdentity? {
        let input = Data(candidate.utf8)
        var matched: SecurityIdentity?
        for entry in entries where constantTimeEqual(entry.key, input) {
            matched = entry.identity
        }
        return matched
    }
}

/// HS256 verifier with explicit issuer, audience, expiration, not-before, and key ID checks.
public struct HMACJWTAuthenticator: Sendable {
    private struct Header: Decodable {
        let alg: String
        let kid: String?
    }

    private struct Claims: Decodable {
        let sub: String
        let iss: String
        let aud: Audience
        let exp: TimeInterval
        let nbf: TimeInterval?
        let roles: [String]?

        enum CodingKeys: String, CodingKey { case sub, iss, aud, exp, nbf, roles }
    }

    private enum Audience: Decodable {
        case one(String)
        case many([String])

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let one = try? value.decode(String.self) {
                self = .one(one)
            } else {
                self = .many(try value.decode([String].self))
            }
        }

        func contains(_ value: String) -> Bool {
            switch self {
            case .one(let audience): audience == value
            case .many(let audiences): audiences.contains(value)
            }
        }
    }

    private let issuer: String
    private let audience: String
    private let keys: [String: Data]
    private let leeway: TimeInterval

    public init(issuer: String, audience: String, keysByID: [String: Data], leeway: TimeInterval = 0) {
        self.issuer = issuer
        self.audience = audience
        self.keys = keysByID
        self.leeway = max(0, leeway)
    }

    public func authenticate(_ token: String, now: Date = Date()) -> SecurityIdentity? {
        guard token.utf8.count <= 16_384 else { return nil }
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let headerData = decodeBase64URL(String(components[0])),
              let claimsData = decodeBase64URL(String(components[1])),
              let signature = decodeBase64URL(String(components[2])),
              let header = try? JSONDecoder().decode(Header.self, from: headerData),
              header.alg == "HS256",
              let keyID = header.kid,
              let secret = keys[keyID],
              HMAC<SHA256>.isValidAuthenticationCode(
                signature,
                authenticating: Data("\(components[0]).\(components[1])".utf8),
                using: SymmetricKey(data: secret)
              ),
              let claims = try? JSONDecoder().decode(Claims.self, from: claimsData) else {
            return nil
        }

        let timestamp = now.timeIntervalSince1970
        guard !claims.sub.isEmpty,
              claims.iss == issuer,
              claims.aud.contains(audience),
              timestamp < claims.exp + leeway,
              claims.nbf.map({ timestamp + leeway >= $0 }) ?? true else {
            return nil
        }
        return SecurityIdentity(subject: claims.sub, roles: Set(claims.roles ?? []))
    }
}

public enum SecurityMiddleware {
    private static let authenticatedKey = HTTPRequest.authenticatedContextKey
    private static let subjectKey = HTTPRequest.subjectContextKey
    private static let rolesKey = HTTPRequest.rolesContextKey

    public static func apiKey(
        _ authenticator: APIKeyAuthenticator,
        header: String = "x-api-key"
    ) -> HTTPMiddleware {
        { request, next in
            guard let key = request.headers[header.lowercased()],
                  let identity = authenticator.authenticate(key) else {
                return secure(HTTPResponse.text("Unauthorized", status: HTTPStatus.unauthorized.rawValue))
            }
            let authenticated = request
                .addingContextValue(authenticatedKey, value: "true")
                .addingContextValue(subjectKey, value: identity.subject)
                .addingContextValue(rolesKey, value: identity.roles.sorted().joined(separator: ","))
            return secure(await next(authenticated))
        }
    }

    public static func bearerToken(
        _ authenticator: HMACJWTAuthenticator,
        header: String = "authorization"
    ) -> HTTPMiddleware {
        { request, next in
            guard let value = request.headers[header.lowercased()],
                  value.hasPrefix("Bearer "),
                  let identity = authenticator.authenticate(String(value.dropFirst("Bearer ".count))) else {
                return secure(HTTPResponse.text("Unauthorized", status: HTTPStatus.unauthorized.rawValue))
            }
            let authenticated = request
                .addingContextValue(authenticatedKey, value: "true")
                .addingContextValue(subjectKey, value: identity.subject)
                .addingContextValue(rolesKey, value: identity.roles.sorted().joined(separator: ","))
            return secure(await next(authenticated))
        }
    }

    /// Authenticates when credentials are present and leaves anonymous handling
    /// to the route policy (for example, `@PermitAll` versus `@Authenticated`).
    public static func optionalBearerToken(
        _ authenticator: HMACJWTAuthenticator,
        header: String = "authorization"
    ) -> HTTPMiddleware {
        { request, next in
            guard let value = request.headers[header.lowercased()] else {
                return secure(await next(request))
            }
            guard value.hasPrefix("Bearer "),
                  let identity = authenticator.authenticate(String(value.dropFirst("Bearer ".count))) else {
                return secure(HTTPResponse.text("Unauthorized", status: HTTPStatus.unauthorized.rawValue))
            }
            let authenticated = request
                .addingContextValue(authenticatedKey, value: "true")
                .addingContextValue(subjectKey, value: identity.subject)
                .addingContextValue(rolesKey, value: identity.roles.sorted().joined(separator: ","))
            return secure(await next(authenticated))
        }
    }

    /// Explicit deny-by-default gate. Install after an authentication middleware.
    public static func denyByDefault() -> HTTPMiddleware {
        { request, next in
            guard request.contextValue(HTTPRequest.permitAllContextKey) == "true"
                    || request.contextValue(authenticatedKey) == "true" else {
                return secure(HTTPResponse.text("Unauthorized", status: HTTPStatus.unauthorized.rawValue))
            }
            return secure(await next(request))
        }
    }

    public static func rolesAllowed(_ roles: Set<String>) -> HTTPMiddleware {
        { request, next in
            if request.contextValue(HTTPRequest.permitAllContextKey) == "true" {
                return secure(await next(request))
            }
            guard request.contextValue(authenticatedKey) == "true" else {
                return secure(HTTPResponse.text("Unauthorized", status: HTTPStatus.unauthorized.rawValue))
            }
            let currentRoles = Set(request.contextValue(rolesKey)?.split(separator: ",").map(String.init) ?? [])
            guard !roles.isDisjoint(with: currentRoles) else {
                return secure(HTTPResponse.text("Forbidden", status: HTTPStatus.forbidden.rawValue))
            }
            return secure(await next(request))
        }
    }

    public static func secureHeaders() -> HTTPMiddleware {
        { request, next in secure(await next(request)) }
    }

    public static func authenticatedSubject(in request: HTTPRequest) -> String? {
        request.contextValue(subjectKey)
    }

    private static func secure(_ response: HTTPResponse) -> HTTPResponse {
        var headers = response.headers
        headers["x-content-type-options"] = "nosniff"
        headers["x-frame-options"] = "DENY"
        headers["referrer-policy"] = "no-referrer"
        return HTTPResponse(status: response.status, headers: headers, body: response.body)
    }
}

private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    let count = max(lhs.count, rhs.count)
    var difference = UInt8(truncatingIfNeeded: lhs.count ^ rhs.count)
    for index in 0..<count {
        let left = index < lhs.count ? lhs[index] : 0
        let right = index < rhs.count ? rhs[index] : 0
        difference |= left ^ right
    }
    return difference == 0
}

private func decodeBase64URL(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: base64)
}

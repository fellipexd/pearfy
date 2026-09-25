import Crypto
import Foundation
import PearfySecurity
import PearfyWeb
import Testing

@Test func apiKeyAuthenticatorMatchesConfiguredIdentities() {
    let authenticator = APIKeyAuthenticator(keys: [
        "first-secret": SecurityIdentity(subject: "service-a", roles: ["READ"]),
        "second-secret": SecurityIdentity(subject: "service-b", roles: ["WRITE"])
    ])
    #expect(authenticator.authenticate("first-secret")?.subject == "service-a")
    #expect(authenticator.authenticate("unknown") == nil)
}

@Test func hmacJWTValidatesSignatureIssuerAudienceTimeAndKeyRotation() throws {
    let oldKey = Data("old-key-material-for-test".utf8)
    let newKey = Data("new-key-material-for-test".utf8)
    let authenticator = HMACJWTAuthenticator(
        issuer: "https://issuer.example",
        audience: "pear-api",
        keysByID: ["old": oldKey, "current": newKey]
    )
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let valid = try makeToken(
        keyID: "current",
        key: newKey,
        claims: [
            "sub": "user-1",
            "iss": "https://issuer.example",
            "aud": ["other", "pear-api"],
            "exp": now.timeIntervalSince1970 + 60,
            "nbf": now.timeIntervalSince1970 - 1,
            "roles": ["ADMIN"]
        ]
    )
    let rotated = try makeToken(
        keyID: "old",
        key: oldKey,
        claims: [
            "sub": "user-2",
            "iss": "https://issuer.example",
            "aud": "pear-api",
            "exp": now.timeIntervalSince1970 + 60
        ]
    )

    #expect(authenticator.authenticate(valid, now: now) == SecurityIdentity(subject: "user-1", roles: ["ADMIN"]))
    #expect(authenticator.authenticate(rotated, now: now)?.subject == "user-2")
    #expect(authenticator.authenticate(valid + "tampered", now: now) == nil)

    let wrongIssuer = try makeToken(
        keyID: "current",
        key: newKey,
        claims: [
            "sub": "user-1",
            "iss": "https://wrong.example",
            "aud": "pear-api",
            "exp": now.timeIntervalSince1970 + 60
        ]
    )
    #expect(authenticator.authenticate(wrongIssuer, now: now) == nil)

    let expired = try makeToken(
        keyID: "current",
        key: newKey,
        claims: [
            "sub": "user-1",
            "iss": "https://issuer.example",
            "aud": "pear-api",
            "exp": now.timeIntervalSince1970 - 1
        ]
    )
    #expect(authenticator.authenticate(expired, now: now) == nil)

    let unsupportedAlgorithm = try makeToken(
        algorithm: "none",
        keyID: "current",
        key: newKey,
        claims: [
            "sub": "user-1",
            "iss": "https://issuer.example",
            "aud": "pear-api",
            "exp": now.timeIntervalSince1970 + 60
        ]
    )
    #expect(authenticator.authenticate(unsupportedAlgorithm, now: now) == nil)
}

@Test func bearerAndRoleMiddlewareDenyByDefault() async throws {
    let secret = Data("middleware-key-material".utf8)
    let authenticator = HMACJWTAuthenticator(
        issuer: "issuer",
        audience: "service",
        keysByID: ["key-1": secret]
    )
    let token = try makeToken(
        keyID: "key-1",
        key: secret,
        claims: [
            "sub": "operator",
            "iss": "issuer",
            "aud": "service",
            "exp": Date().timeIntervalSince1970 + 60,
            "roles": ["ADMIN"]
        ]
    )
    let router = HTTPRouter()
    try await router.use(SecurityMiddleware.bearerToken(authenticator))
    try await router.use(SecurityMiddleware.denyByDefault())
    try await router.use(SecurityMiddleware.rolesAllowed(["ADMIN"]))
    try await router.get("/admin") { request in
        .text(SecurityMiddleware.authenticatedSubject(in: request) ?? "missing identity")
    }
    try await router.freeze()

    let anonymous = await router.handle(try HTTPRequest(method: .get, target: "/admin"))
    let authorized = await router.handle(try HTTPRequest(
        method: .get,
        target: "/admin",
        headers: ["authorization": "Bearer \(token)"]
    ))
    #expect(anonymous.status == 401)
    #expect(authorized.status == 200)
    #expect(authorized.headers["x-content-type-options"] == "nosniff")
    #expect(String(decoding: authorized.body, as: UTF8.self) == "operator")
}

private func makeToken(
    algorithm: String = "HS256",
    keyID: String,
    key: Data,
    claims: [String: Any]
) throws -> String {
    let header = try JSONSerialization.data(withJSONObject: ["alg": algorithm, "kid": keyID, "typ": "JWT"])
    let payload = try JSONSerialization.data(withJSONObject: claims)
    let encodedHeader = base64URL(header)
    let encodedPayload = base64URL(payload)
    let signingInput = Data("\(encodedHeader).\(encodedPayload)".utf8)
    let signature = HMAC<SHA256>.authenticationCode(for: signingInput, using: SymmetricKey(data: key))
    return "\(encodedHeader).\(encodedPayload).\(base64URL(Data(signature)))"
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

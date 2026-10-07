import Foundation
import PearfyGameServer
import PearfyGameServerGRPC
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import Testing

@available(macOS 15, iOS 18, *)
@Test func gameServerGRPCConfigurationRejectsUnboundedAggregatePayloads() throws {
    #expect(throws: GameServerGRPCError.invalidConfiguration) {
        try GameServerGRPCConfiguration(
            certificateChainPath: "/dev/null",
            privateKeyPath: "/dev/null",
            maximumMessageBytes: 1_048_576,
            maximumConcurrentStreamsPerConnection: 128,
            maximumConnections: 256,
            maximumAggregateInFlightPayloadBytes: 268_435_456
        )
    }
}

@available(macOS 15, iOS 18, *)
@Test func gameServerGRPCUnaryControlUsesTLSBearerAuthAndBoundedCallbacks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pearfy-grpc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let certificate = directory.appendingPathComponent("cert.pem")
    let privateKey = directory.appendingPathComponent("key.pem")
    let openssl = Process()
    openssl.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    openssl.arguments = ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", privateKey.path,
                         "-out", certificate.path, "-days", "1", "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1"]
    openssl.standardOutput = FileHandle.nullDevice
    openssl.standardError = FileHandle.nullDevice
    try openssl.run()
    openssl.waitUntilExit()
    #expect(openssl.terminationStatus == 0)

    let principal = GameSessionPrincipal(sessionID: UUID(), playerID: UUID(), protocolVersion: 1)
    let server = GameServerGRPCServer(
        configuration: try GameServerGRPCConfiguration(port: 0, certificateChainPath: certificate.path, privateKeyPath: privateKey.path),
        authorize: { authorization in
            guard authorization == "Bearer valid-test-ticket" else { throw TestGRPCAuthError.rejected }
            return principal
        },
        dispatch: { method, payload, authorizedPrincipal in
            guard method == .join, authorizedPrincipal == principal else { throw TestGRPCAuthError.rejected }
            return payload
        }
    )
    let endpoint = try await server.start()
    let port = try #require(endpoint.split(separator: ":").last.flatMap { Int($0) })

    let transport = try HTTP2ClientTransport.Posix(
        target: .ipv4(address: "127.0.0.1", port: port),
        transportSecurity: .tls(.defaults { $0.serverCertificateVerification = .noVerification })
    )
    let payload = Data("join-request".utf8)
    let response = try await withGRPCClient(transport: transport) { client in
        let session = Pearfy_Game_V1_GameSession.Client(wrapping: client)
        return try await session.join(
            Pearfy_Common_V1_ControlRequest.with { $0.payload = payload },
            metadata: ["authorization": "Bearer valid-test-ticket"]
        )
    }
    #expect(response.payload == payload)

    let rejectedTransport = try HTTP2ClientTransport.Posix(
        target: .ipv4(address: "127.0.0.1", port: port),
        transportSecurity: .tls(.defaults { $0.serverCertificateVerification = .noVerification })
    )
    do {
        _ = try await withGRPCClient(transport: rejectedTransport) { client in
            let session = Pearfy_Game_V1_GameSession.Client(wrapping: client)
            return try await session.join(Pearfy_Common_V1_ControlRequest.with { $0.payload = payload })
        }
        Issue.record("server accepted a request without bearer authorization")
    } catch let error as RPCError {
        #expect(error.code == .unauthenticated)
    }
    try await server.stop()
}

private enum TestGRPCAuthError: Error, Sendable {
    case rejected
}

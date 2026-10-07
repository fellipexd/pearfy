import Foundation
import PearfyGameServer
import PearfyGameServerGRPC
import PearfyGameServerTransport
import PearfyNetwork
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import Testing

@Test func pearfyNetworkClientCompletesTicketAdmittedGameServerUDPSocketRoundTrip() async throws {
    let gameSessionID = UUID()
    let playerID = UUID()
    let authority = try GameSessionTicketAuthority(
        configuration: GameServerConfiguration(),
        signingKey: Data(repeating: 0x73, count: 32)
    )
    let ticket = try await authority.issue(sessionID: gameSessionID, playerID: playerID)

    let configuration = try GameServerUDPConfiguration(
        host: "127.0.0.1",
        port: 0,
        maximumDatagramBytes: 1_200
    )
    let server = GameServerUDPServer(configuration: configuration) { principal, payload in
        guard principal.sessionID == gameSessionID,
              principal.playerID == playerID,
              principal.protocolVersion == 1,
              payload == Data("move:north".utf8) else { return nil }
        return Data("ok:north".utf8)
    }
    let admission = try GameServerUDPAdmissionManager(
        ticketAuthority: authority,
        server: server,
        maximumPayloadBytes: configuration.maximumPayloadBytes
    )
    try await server.start()

    do {
        let credentials = try await admission.admit(
            ticket: ticket,
            sessionID: gameSessionID,
            playerID: playerID,
            protocolVersion: 1
        )
        let boundPort = try #require(await server.boundPort())
        let sessionSecret = credentials.sessionSecret.withUnsafeBytes { Data($0) }
        let client = try SecureUDPTransport(
            host: "127.0.0.1",
            port: UInt16(boundPort),
            sessionID: credentials.channelID,
            sessionSecret: sessionSecret,
            maximumPayloadBytes: configuration.maximumPayloadBytes
        )

        do {
            try await client.connect()
            try await client.send(Data("move:north".utf8))
            let response = try await client.receive()
            #expect(response == Data("ok:north".utf8))
            await client.close()
        } catch {
            await client.close()
            throw error
        }

        await admission.revoke(channelID: credentials.channelID)
        try await server.stop()
    } catch {
        try? await server.stop()
        throw error
    }
}

@Test func pearfyNetworkPlayersStayWithinIndependentUDPWorkBudgetsUnderBurstLoad() async throws {
    let gameSessionID = UUID()
    let playerIDs = [UUID(), UUID()]
    let authority = try GameSessionTicketAuthority(
        configuration: GameServerConfiguration(),
        signingKey: Data(repeating: 0x29, count: 32)
    )
    var tickets: [GameSessionTicket] = []
    for playerID in playerIDs {
        tickets.append(try await authority.issue(sessionID: gameSessionID, playerID: playerID))
    }
    let configuration = try GameServerUDPConfiguration(
        host: "127.0.0.1",
        port: 0,
        maximumDatagramBytes: 1_200,
        maximumPacketsPerSecond: 100,
        maximumPacketsPerSecondPerSession: 4
    )
    let dispatchCounter = UDPDispatchCounter()
    let server = GameServerUDPServer(configuration: configuration) { principal, payload in
        guard principal.sessionID == gameSessionID,
              playerIDs.contains(principal.playerID),
              payload.starts(with: Data("input".utf8)) else { return nil }
        await dispatchCounter.record(playerID: principal.playerID)
        return Data("ack".utf8)
    }
    let admission = try GameServerUDPAdmissionManager(
        ticketAuthority: authority,
        server: server,
        maximumPayloadBytes: configuration.maximumPayloadBytes
    )
    try await server.start()

    do {
        var credentials: [GameServerUDPAdmissionCredentials] = []
        for (ticket, playerID) in zip(tickets, playerIDs) {
            credentials.append(try await admission.admit(
                ticket: ticket,
                sessionID: gameSessionID,
                playerID: playerID,
                protocolVersion: 1
            ))
        }
        let port = UInt16(try #require(await server.boundPort()))
        let clients = try zip(credentials, playerIDs).map { credentials, _ in
            try SecureUDPTransport(
                host: "127.0.0.1",
                port: port,
                sessionID: credentials.channelID,
                sessionSecret: credentials.sessionSecret.withUnsafeBytes { Data($0) },
                maximumPayloadBytes: configuration.maximumPayloadBytes
            )
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for client in clients {
                group.addTask { try await client.connect() }
            }
            try await group.waitForAll()
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for clientIndex in clients.indices {
                    group.addTask {
                        for packetIndex in 0..<10 {
                            let input = Data("input-\(clientIndex)-\(packetIndex)".utf8)
                            try await clients[clientIndex].send(input)
                        }
                    }
                }
                try await group.waitForAll()
            }

            for _ in 0..<100 {
                if await dispatchCounter.total == 8 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await dispatchCounter.total == 8)
            #expect(await dispatchCounter.count(for: playerIDs[0]) == 4)
            #expect(await dispatchCounter.count(for: playerIDs[1]) == 4)
        } catch {
            for client in clients { await client.close() }
            throw error
        }

        for client in clients { await client.close() }
        for credential in credentials { await admission.revoke(channelID: credential.channelID) }
        try await server.stop()
    } catch {
        try? await server.stop()
        throw error
    }
}

private actor UDPDispatchCounter {
    private var counts: [UUID: Int] = [:]

    var total: Int { counts.values.reduce(0, +) }

    func count(for playerID: UUID) -> Int { counts[playerID, default: 0] }

    func record(playerID: UUID) { counts[playerID, default: 0] += 1 }
}

@available(macOS 15, iOS 18, *)
@Test func tlsJoinDeliversTicketAdmittedCredentialsUsedByPearfyNetworkUDPClient() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-udp-interop-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let certificate = directory.appendingPathComponent("cert.pem")
    let privateKey = directory.appendingPathComponent("key.pem")
    let openssl = Process()
    openssl.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    openssl.arguments = [
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", privateKey.path, "-out", certificate.path, "-days", "1",
        "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1"
    ]
    openssl.standardOutput = FileHandle.nullDevice
    openssl.standardError = FileHandle.nullDevice
    try openssl.run()
    openssl.waitUntilExit()
    #expect(openssl.terminationStatus == 0)

    let gameSessionID = UUID()
    let playerID = UUID()
    let ticketAuthority = try GameSessionTicketAuthority(
        configuration: GameServerConfiguration(),
        signingKey: Data(repeating: 0x51, count: 32)
    )
    let ticket = try await ticketAuthority.issue(sessionID: gameSessionID, playerID: playerID)
    let udpConfiguration = try GameServerUDPConfiguration(host: "127.0.0.1", port: 0)
    let gameServer = GameServerUDPServer(configuration: udpConfiguration) { principal, payload in
        guard principal.sessionID == gameSessionID,
              principal.playerID == playerID,
              payload == Data("input:42".utf8) else { return nil }
        return Data("ack:42".utf8)
    }
    let admission = try GameServerUDPAdmissionManager(
        ticketAuthority: ticketAuthority,
        server: gameServer,
        maximumPayloadBytes: udpConfiguration.maximumPayloadBytes
    )
    try await gameServer.start()

    let controlServer = GameServerGRPCServer(
        configuration: try GameServerGRPCConfiguration(
            host: "127.0.0.1", port: 0,
            certificateChainPath: certificate.path,
            privateKeyPath: privateKey.path
        ),
        authorize: { authorization in
            guard authorization == ticket.bearerAuthorizationValue,
                  let principal = await ticketAuthority.authenticate(
                    ticket,
                    sessionID: gameSessionID,
                    playerID: playerID,
                    protocolVersion: 1
                  ) else { throw UDPInteropAuthorizationError.rejected }
            return principal
        },
        dispatch: { method, _, principal in
            guard method == .join,
                  principal.sessionID == gameSessionID,
                  principal.playerID == playerID else { throw UDPInteropAuthorizationError.rejected }
            let credentials = try await admission.admit(
                ticket: ticket,
                sessionID: gameSessionID,
                playerID: playerID,
                protocolVersion: 1
            )
            return try JSONEncoder().encode(UDPJoinCredentials(
                channelID: credentials.channelID,
                sessionSecret: credentials.sessionSecret.withUnsafeBytes { Data($0) }
            ))
        }
    )

    do {
        let endpoint = try await controlServer.start()
        let controlPort = try #require(endpoint.split(separator: ":").last.flatMap { Int($0) })
        let controlTransport = try HTTP2ClientTransport.Posix(
            target: .ipv4(address: "127.0.0.1", port: controlPort),
            transportSecurity: .tls(.defaults {
                $0.trustRoots = .certificates([.file(path: certificate.path, format: .pem)])
            })
        )
        let response = try await withGRPCClient(transport: controlTransport) { client in
            let gameSession = Pearfy_Game_V1_GameSession.Client(wrapping: client)
            return try await gameSession.join(
                Pearfy_Common_V1_ControlRequest.with { $0.payload = Data("join".utf8) },
                metadata: ["authorization": .string(ticket.bearerAuthorizationValue)]
            )
        }
        let credentials = try JSONDecoder().decode(UDPJoinCredentials.self, from: response.payload)
        let udpPort = UInt16(try #require(await gameServer.boundPort()))
        let udpClient = try SecureUDPTransport(
            host: "127.0.0.1",
            port: udpPort,
            sessionID: credentials.channelID,
            sessionSecret: credentials.sessionSecret,
            maximumPayloadBytes: udpConfiguration.maximumPayloadBytes
        )
        do {
            try await udpClient.connect()
            try await udpClient.send(Data("input:42".utf8))
            #expect(try await udpClient.receive() == Data("ack:42".utf8))
        } catch {
            await udpClient.close()
            throw error
        }
        await udpClient.close()
        await admission.revoke(channelID: credentials.channelID)
        try await controlServer.stop()
        try await gameServer.stop()
    } catch {
        try? await controlServer.stop()
        try? await gameServer.stop()
        throw error
    }
}

private struct UDPJoinCredentials: Codable {
    let channelID: UUID
    let sessionSecret: Data
}

private enum UDPInteropAuthorizationError: Error, Sendable {
    case rejected
}

import Foundation
import PearfyGameServer
@testable import PearfyGameServerTransport
import Testing
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import NIOSSL
import Crypto

@Test func secureGameServerDatagramsEncryptAuthenticateAndRejectReplays() throws {
    let sessionID = UUID()
    let secret = SymmetricKey(size: .bits256)
    let client = try GameServerSecureDatagramCodec(sessionID: sessionID, sessionSecret: secret, role: .client)
    let server = try GameServerSecureDatagramCodec(sessionID: sessionID, sessionSecret: secret, role: .server)
    let command = Data("move:4,2".utf8)

    let packet = try client.seal(command)
    #expect(packet.count == GameServerSecureDatagramCodec.headerBytes + command.count + GameServerSecureDatagramCodec.authenticationTagBytes)
    #expect(packet.suffix(from: GameServerSecureDatagramCodec.headerBytes) != command)
    #expect(try server.open(packet) == command)
    #expect(throws: GameServerSecureDatagramError.replayDetected) { try server.open(packet) }

    let response = Data("snapshot:8".utf8)
    #expect(try client.open(server.seal(response)) == response)
}

@Test func pearfyNetworkClientMatchesSharedSecureUDPWireVector() throws {
    let sessionID = try #require(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))
    let secret = SymmetricKey(data: Data((0..<32).map(UInt8.init)))
    let client = try GameServerSecureDatagramCodec(sessionID: sessionID, sessionSecret: secret, role: .client)
    let packet = try client.seal(Data("move:4,2".utf8))
    #expect(packet.map { String(format: "%02x", $0) }.joined() == "504653550100000000112233445566778899aabbccddeeff0000000000000001df1ed43d8797660f7b7293249304836093c8ed6201808ea9")
}

@Test func secureGameServerDatagramsRejectTamperingWrongSessionsAndOversizedPayloads() throws {
    let sessionID = UUID()
    let secret = SymmetricKey(size: .bits256)
    let client = try GameServerSecureDatagramCodec(sessionID: sessionID, sessionSecret: secret, role: .client,
                                                   maximumPayloadBytes: 32)
    let server = try GameServerSecureDatagramCodec(sessionID: sessionID, sessionSecret: secret, role: .server,
                                                   maximumPayloadBytes: 32)
    var packet = try client.seal(Data("input".utf8))
    packet[GameServerSecureDatagramCodec.headerBytes] ^= 0x80
    #expect(throws: GameServerSecureDatagramError.authenticationFailed) { try server.open(packet) }
    let validPacket = try client.seal(Data("valid".utf8))
    #expect(try server.open(validPacket) == Data("valid".utf8))

    let otherSession = try GameServerSecureDatagramCodec(sessionID: UUID(), sessionSecret: secret, role: .server)
    #expect(throws: GameServerSecureDatagramError.wrongSession) { try otherSession.open(validPacket) }
    #expect(throws: GameServerSecureDatagramError.payloadTooLarge) { try client.seal(Data(repeating: 1, count: 33)) }
    #expect(throws: GameServerSecureDatagramError.invalidConfiguration) {
        try GameServerSecureDatagramCodec(sessionID: sessionID, sessionSecret: SymmetricKey(data: Data(repeating: 1, count: 16)), role: .client)
    }
}

@Test func secureGameServerDatagramsAcceptBoundedReorderingOnlyOnce() throws {
    let sessionID = UUID()
    let secret = SymmetricKey(size: .bits256)
    let client = try GameServerSecureDatagramCodec(sessionID: sessionID, sessionSecret: secret, role: .client)
    let server = try GameServerSecureDatagramCodec(sessionID: sessionID, sessionSecret: secret, role: .server)
    let packets = try (0..<3).map { try client.seal(Data([UInt8($0)])) }
    #expect(try server.open(packets[2]) == Data([2]))
    #expect(try server.open(packets[0]) == Data([0]))
    #expect(throws: GameServerSecureDatagramError.replayDetected) { try server.open(packets[0]) }
    #expect(try server.open(packets[1]) == Data([1]))
}

@Test func udpAdmissionLimiterEnforcesGlobalAndPerSessionBudgets() {
    var limiter = GameServerUDPWindowLimiter()
    let start = ContinuousClock.now
    let firstSession = UUID()
    let secondSession = UUID()

    let firstAdmitted = limiter.admit(sessionID: firstSession, now: start, maximumTotal: 3, maximumPerSession: 2)
    let secondAdmitted = limiter.admit(sessionID: firstSession, now: start, maximumTotal: 3, maximumPerSession: 2)
    let sameSessionOverBudget = limiter.admit(sessionID: firstSession, now: start, maximumTotal: 3, maximumPerSession: 2)
    let otherSessionAdmitted = limiter.admit(sessionID: secondSession, now: start, maximumTotal: 3, maximumPerSession: 2)
    let globalOverBudget = limiter.admit(sessionID: UUID(), now: start, maximumTotal: 3, maximumPerSession: 2)
    let admittedAfterWindowReset = limiter.admit(
        sessionID: firstSession,
        now: start.advanced(by: .seconds(1)),
        maximumTotal: 3,
        maximumPerSession: 2
    )
    #expect(firstAdmitted)
    #expect(secondAdmitted)
    #expect(!sameSessionOverBudget)
    #expect(otherSessionAdmitted)
    #expect(!globalOverBudget)
    #expect(admittedAfterWindowReset)
}

@Test func udpAdmissionLimiterEnforcesRollingOneSecondLimitAcrossWindowBoundaries() {
    var limiter = GameServerUDPWindowLimiter()
    let start = ContinuousClock.now
    let first = UUID()
    let second = UUID()
    let duringWindow = start.advanced(by: .milliseconds(999))
    let nextWindow = start.advanced(by: .seconds(1))

    let firstAccepted = limiter.admit(sessionID: first, now: start, maximumTotal: 2, maximumPerSession: 2)
    let secondAccepted = limiter.admit(sessionID: second, now: start, maximumTotal: 2, maximumPerSession: 2)
    let boundaryBurstAccepted = limiter.admit(
        sessionID: UUID(), now: duringWindow, maximumTotal: 2, maximumPerSession: 2
    )
    let acceptedAfterRollingWindow = limiter.admit(
        sessionID: UUID(), now: nextWindow, maximumTotal: 2, maximumPerSession: 2
    )
    #expect(firstAccepted)
    #expect(secondAccepted)
    #expect(!boundaryBurstAccepted)
    #expect(acceptedAfterRollingWindow)
}

@Test func secureGameServerUDPServerDispatchesEncryptedPacketsAndRespondsToSender() async throws {
    let sessionID = UUID()
    let playerID = UUID()
    let secondPlayerID = UUID()
    let ticketAuthority = try GameSessionTicketAuthority(
        configuration: GameServerConfiguration(),
        signingKey: Data(repeating: 0x42, count: 32)
    )
    let ticket = try await ticketAuthority.issue(sessionID: sessionID, playerID: playerID)
    let secondTicket = try await ticketAuthority.issue(sessionID: sessionID, playerID: secondPlayerID)
    let server = GameServerUDPServer(configuration: try GameServerUDPConfiguration(
        host: "127.0.0.1", port: 0, maximumPacketsPerSecondPerSession: 1
    )) { principal, payload in
        guard principal.sessionID == sessionID,
              [playerID, secondPlayerID].contains(principal.playerID),
              let text = String(data: payload, encoding: .utf8) else { return nil }
        return Data(text.uppercased().utf8)
    }
    let admission = try GameServerUDPAdmissionManager(ticketAuthority: ticketAuthority, server: server)
    try await server.start()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        do {
            _ = try await admission.admit(
                ticket: ticket, sessionID: sessionID, playerID: UUID(), protocolVersion: 1
            )
            Issue.record("a ticket cannot authorize a different player")
        } catch {
            #expect(error as? GameServerUDPAdmissionError == .unauthorizedTicket)
        }
        let revokedTicket = try await ticketAuthority.issue(sessionID: sessionID, playerID: UUID())
        #expect(await ticketAuthority.revoke(revokedTicket))
        do {
            _ = try await admission.admit(
                ticket: revokedTicket,
                sessionID: sessionID,
                playerID: UUID(),
                protocolVersion: 1
            )
            Issue.record("a revoked ticket cannot register a datagram channel")
        } catch {
            #expect(error as? GameServerUDPAdmissionError == .unauthorizedTicket)
        }
        let expiredPlayerID = UUID()
        let expiredTicket = try await ticketAuthority.issue(
            sessionID: sessionID,
            playerID: expiredPlayerID,
            now: Date(timeIntervalSince1970: 1)
        )
        do {
            _ = try await admission.admit(
                ticket: expiredTicket,
                sessionID: sessionID,
                playerID: expiredPlayerID,
                protocolVersion: 1,
                now: Date(timeIntervalSince1970: 122)
            )
            Issue.record("an expired ticket cannot register a datagram channel")
        } catch {
            #expect(error as? GameServerUDPAdmissionError == .unauthorizedTicket)
        }
        let credentials = try await admission.admit(
            ticket: ticket, sessionID: sessionID, playerID: playerID, protocolVersion: 1
        )
        let secondCredentials = try await admission.admit(
            ticket: secondTicket, sessionID: sessionID, playerID: secondPlayerID, protocolVersion: 1
        )
        #expect(credentials.channelID != sessionID)
        #expect(credentials.channelID != secondCredentials.channelID)
        #expect(credentials.description == "<game-server-udp-credentials:redacted>")
        let clientCodec = try GameServerSecureDatagramCodec(
            sessionID: credentials.channelID,
            sessionSecret: credentials.sessionSecret,
            role: .client,
            maximumPayloadBytes: 1_152
        )
        let secondClientCodec = try GameServerSecureDatagramCodec(
            sessionID: secondCredentials.channelID,
            sessionSecret: secondCredentials.sessionSecret,
            role: .client,
            maximumPayloadBytes: 1_152
        )
        let clientCodecs = [credentials.channelID: clientCodec, secondCredentials.channelID: secondClientCodec]
        let port = try #require(await server.boundPort())
        let client = try await DatagramBootstrap(group: group).bind(host: "127.0.0.1", port: 0) { channel in
            channel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<UDPTestEnvelope, UDPTestEnvelope>(wrappingChannelSynchronously: channel)
            }
        }
        let responses: [Data]? = try await client.executeThenClose { inbound, outbound in
            let destination = try SocketAddress(ipAddress: "127.0.0.1", port: port)
            for _ in 0..<2 {
                var forged = try clientCodec.seal(Data("forged".utf8))
                forged[GameServerSecureDatagramCodec.headerBytes] ^= 0x80
                var forgedBuffer = ByteBufferAllocator().buffer(capacity: forged.count)
                forgedBuffer.writeBytes(forged)
                try await outbound.write(UDPTestEnvelope(remoteAddress: destination, data: forgedBuffer))
            }

            let packet = try clientCodec.seal(Data("move north".utf8))
            var buffer = ByteBufferAllocator().buffer(capacity: packet.count)
            buffer.writeBytes(packet)
            try await outbound.write(UDPTestEnvelope(remoteAddress: destination, data: buffer))
            let secondPacket = try secondClientCodec.seal(Data("move east".utf8))
            var secondBuffer = ByteBufferAllocator().buffer(capacity: secondPacket.count)
            secondBuffer.writeBytes(secondPacket)
            try await outbound.write(UDPTestEnvelope(remoteAddress: destination, data: secondBuffer))
            return try await withThrowingTaskGroup(of: [Data]?.self) { tasks in
                tasks.addTask {
                    var responses: [UUID: Data] = [:]
                    for try await envelope in inbound {
                        let responsePacket = Data(envelope.data.readableBytesView)
                        guard let responseChannelID = GameServerSecureDatagramCodec.sessionID(in: responsePacket),
                              let responseCodec = clientCodecs[responseChannelID] else { continue }
                        responses[responseChannelID] = try responseCodec.open(responsePacket)
                        if responses.count == 2,
                           let first = responses[credentials.channelID],
                           let second = responses[secondCredentials.channelID] {
                            return [first, second]
                        }
                    }
                    return nil
                }
                tasks.addTask {
                    try await Task.sleep(for: .seconds(1))
                    return nil
                }
                let result = try await tasks.next() ?? nil
                tasks.cancelAll()
                return result
            }
        }
        #expect(responses == [Data("MOVE NORTH".utf8), Data("MOVE EAST".utf8)])
        await admission.revoke(channelID: credentials.channelID)
        await admission.revoke(channelID: secondCredentials.channelID)
        try await server.stop()
        await shutdownUDPEventLoopGroup(group)
    } catch {
        try? await server.stop()
        await shutdownUDPEventLoopGroup(group)
        throw error
    }
}

@Test func secureGameServerUDPServerDropsReplayedDatagramsBeforeGameHandler() async throws {
    let sessionID = UUID()
    let playerID = UUID()
    let secret = SymmetricKey(size: .bits256)
    let clientCodec = try GameServerSecureDatagramCodec(sessionID: sessionID, sessionSecret: secret, role: .client,
                                                        maximumPayloadBytes: 1_152)
    let serverCodec = try GameServerSecureDatagramCodec(sessionID: sessionID, sessionSecret: secret, role: .server,
                                                        maximumPayloadBytes: 1_152)
    let invocations = UDPMessageInvocationCounter()
    let server = GameServerUDPServer(
        configuration: try GameServerUDPConfiguration(host: "127.0.0.1", port: 0),
        onMessage: { _, payload in
            await invocations.increment()
            return payload
        }
    )
    try await server.register(
        sessionID: sessionID,
        principal: GameSessionPrincipal(sessionID: sessionID, playerID: playerID, protocolVersion: 1),
        codec: serverCodec
    )
    try await server.start()

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let port = try #require(await server.boundPort())
        let client = try await DatagramBootstrap(group: group).bind(host: "127.0.0.1", port: 0) { channel in
            channel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<UDPTestEnvelope, UDPTestEnvelope>(wrappingChannelSynchronously: channel)
            }
        }
        let response: Data? = try await client.executeThenClose { inbound, outbound in
            let packet = try clientCodec.seal(Data("jump".utf8))
            let destination = try SocketAddress(ipAddress: "127.0.0.1", port: port)
            for _ in 0..<2 {
                var buffer = ByteBufferAllocator().buffer(capacity: packet.count)
                buffer.writeBytes(packet)
                try await outbound.write(UDPTestEnvelope(remoteAddress: destination, data: buffer))
            }
            for try await envelope in inbound {
                return try clientCodec.open(Data(envelope.data.readableBytesView))
            }
            return nil
        }
        #expect(response == Data("jump".utf8))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await invocations.count() == 1)
        await server.unregister(sessionID: sessionID)
        try await server.stop()
        await shutdownUDPEventLoopGroup(group)
    } catch {
        await server.unregister(sessionID: sessionID)
        try? await server.stop()
        await shutdownUDPEventLoopGroup(group)
        throw error
    }
}

@Test func secureGameServerUDPConfigurationAndSessionRegistryEnforceHardBounds() async throws {
    let configuration = try GameServerUDPConfiguration(maximumDatagramBytes: 1_200)
    #expect(configuration.maximumPayloadBytes == 1_152)
    #expect(throws: GameServerUDPError.invalidConfiguration) {
        try GameServerUDPConfiguration(maximumDatagramBytes: 47)
    }
    #expect(throws: GameServerUDPError.invalidConfiguration) {
        try GameServerUDPConfiguration(maximumDatagramBytes: 1_200, maximumBufferedDatagrams: 2,
                                       maximumAggregateBufferedBytes: 1_200)
    }
    #expect(throws: GameServerUDPError.invalidConfiguration) {
        try GameServerUDPConfiguration(maximumPacketsPerSecond: 100, maximumPacketsPerSecondPerSession: 101)
    }

    let sessionID = UUID()
    let principal = GameSessionPrincipal(sessionID: sessionID, playerID: UUID(), protocolVersion: 1)
    let secret = SymmetricKey(size: .bits256)
    let server = GameServerUDPServer(
        configuration: try GameServerUDPConfiguration(maximumSessions: 1),
        onMessage: { _, _ in nil }
    )
    let clientCodec = try GameServerSecureDatagramCodec(sessionID: sessionID, sessionSecret: secret, role: .client,
                                                        maximumPayloadBytes: 1_152)
    await expectUDPError(.invalidSessionCodec) {
        try await server.register(sessionID: sessionID, principal: principal, codec: clientCodec)
    }
    let serverCodec = try GameServerSecureDatagramCodec(sessionID: sessionID, sessionSecret: secret, role: .server,
                                                        maximumPayloadBytes: 1_152)
    try await server.register(sessionID: sessionID, principal: principal, codec: serverCodec)
    await expectUDPError(.duplicateSession) {
        try await server.register(sessionID: sessionID, principal: principal, codec: serverCodec)
    }
    let secondID = UUID()
    let secondCodec = try GameServerSecureDatagramCodec(sessionID: secondID, sessionSecret: secret, role: .server,
                                                        maximumPayloadBytes: 1_152)
    await expectUDPError(.sessionCapacityReached) {
        try await server.register(
            sessionID: secondID,
            principal: GameSessionPrincipal(sessionID: secondID, playerID: UUID(), protocolVersion: 1),
            codec: secondCodec
        )
    }
}

private typealias UDPTestEnvelope = AddressedEnvelope<ByteBuffer>

private actor UDPMessageInvocationCounter {
    private var value = 0
    func increment() { value += 1 }
    func count() -> Int { value }
}

private func shutdownUDPEventLoopGroup(_ group: MultiThreadedEventLoopGroup) async {
    await withCheckedContinuation { continuation in
        group.shutdownGracefully { _ in continuation.resume() }
    }
}

private func expectUDPError(_ expected: GameServerUDPError, operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("expected UDP configuration error was not thrown")
    } catch let error as GameServerUDPError {
        #expect(error == expected)
    } catch {
        Issue.record("received an unexpected UDP error type")
    }
}

@Test func gameServerWebSocketConfigurationRejectsUnsafeOrUnboundedSettings() throws {
    #expect(throws: GameServerWebSocketError.invalidConfiguration) {
        try GameServerWebSocketConfiguration(path: "gameserver", certificatePath: "cert.pem", privateKeyPath: "key.pem")
    }
    #expect(throws: GameServerWebSocketError.invalidConfiguration) {
        try GameServerWebSocketConfiguration(path: "/gameserver?token=unsafe", certificatePath: "cert.pem", privateKeyPath: "key.pem")
    }
    #expect(throws: GameServerWebSocketError.invalidConfiguration) {
        try GameServerWebSocketConfiguration(host: "127.0.0.1", port: 8443, path: "/gameserver",
                                             certificatePath: "cert.pem", privateKeyPath: "key.pem",
                                             maximumConnections: 100, maximumMessageBytes: 1_048_577,
                                             maximumMessagesPerSecondPerConnection: 120)
    }
    #expect(throws: GameServerWebSocketError.invalidConfiguration) {
        try GameServerWebSocketConfiguration(host: "127.0.0.1", port: 8443, path: "/gameserver",
                                             certificatePath: "cert.pem", privateKeyPath: "key.pem",
                                             maximumConnections: 103, maximumMessageBytes: 1_024,
                                             maximumBufferedFramesPerConnection: 10, maximumAggregateBufferedPayloadBytes: 1_048_576)
    }
}

@Test func gameServerWebSocketGatewayBindsTLSListenerAndDrainsOnStop() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pearfy-wss-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let certificate = directory.appendingPathComponent("cert.pem")
    let privateKey = directory.appendingPathComponent("key.pem")
    let openssl = Process()
    openssl.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    openssl.arguments = ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", privateKey.path,
                         "-out", certificate.path, "-days", "1", "-subj", "/CN=localhost"]
    openssl.standardOutput = FileHandle.nullDevice
    openssl.standardError = FileHandle.nullDevice
    try openssl.run(); openssl.waitUntilExit()
    #expect(openssl.terminationStatus == 0)

    let config = try GameServerWebSocketConfiguration(port: 0, certificatePath: certificate.path, privateKeyPath: privateKey.path)
    let gateway = GameServerWebSocketGateway(configuration: config, authorize: { _ in nil }, onMessage: { _, _ in nil })
    try await gateway.start()
    #expect(await gateway.boundPort() != nil)
    try await gateway.stop()
    #expect(await gateway.boundPort() == nil)
}

@Test func gameServerWebSocketGatewayAuthenticatesAndDispatchesMessagesOverTLS() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pearfy-wss-message-\(UUID().uuidString)", isDirectory: true)
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
    try openssl.run(); openssl.waitUntilExit()
    #expect(openssl.terminationStatus == 0)

    let principal = GameSessionPrincipal(sessionID: UUID(), playerID: UUID(), protocolVersion: 1)
    let gateway = GameServerWebSocketGateway(
        configuration: try GameServerWebSocketConfiguration(port: 0, certificatePath: certificate.path, privateKeyPath: privateKey.path),
        authorize: { token in token == "valid-test-ticket" ? principal : nil },
        onMessage: { principal, payload in
            guard principal.protocolVersion == 1 else { return nil }
            return payload
        }
    )
    try await gateway.start()
    defer { Task { try? await gateway.stop() } }
    let port = try #require(await gateway.boundPort())

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { group.shutdownGracefully { _ in } }
    var clientTLS = TLSConfiguration.makeClientConfiguration()
    clientTLS.certificateVerification = .none // The test uses an ephemeral self-signed certificate.
    let context = try NIOSSLContext(configuration: clientTLS)
    let payload = Data("authoritative-command".utf8)
    let upgrade = try await connectTestGateway(group: group, port: port, context: context, bearer: "valid-test-ticket")
    guard case .websocket(let socket) = upgrade else {
        Issue.record("server refused a valid bearer ticket")
        return
    }
    let response = try await socket.executeThenClose { inbound, outbound in
        var buffer = socket.channel.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        try await outbound.write(WebSocketFrame(fin: true, opcode: .binary, data: buffer))
        for try await frame in inbound where frame.opcode == .binary { return Data(frame.unmaskedData.readableBytesView) }
        return Data()
    }
    #expect(response == payload)
    let rejected = try await connectTestGateway(group: group, port: port, context: context, bearer: "revoked-test-ticket")
    guard case .notUpgraded = rejected else {
        Issue.record("server admitted an invalid or revoked ticket")
        return
    }
}

private enum TestWebSocketUpgrade: Sendable {
    case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
    case notUpgraded
}

private func connectTestGateway(group: MultiThreadedEventLoopGroup, port: Int, context: NIOSSLContext,
                                bearer: String) async throws -> TestWebSocketUpgrade {
    let upgrade: EventLoopFuture<TestWebSocketUpgrade> = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: port) { channel in
        channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: "localhost"))
            let upgrader = NIOTypedWebSocketClientUpgrader<TestWebSocketUpgrade>(upgradePipelineHandler: { channel, _ in
                channel.eventLoop.makeCompletedFuture {
                    .websocket(try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: channel))
                }
            })
            var headers = HTTPHeaders()
            headers.add(name: "Authorization", value: "Bearer \(bearer)")
            headers.add(name: "Content-Length", value: "0")
            let request = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/gameserver", headers: headers)
            let clientUpgrade = NIOTypedHTTPClientUpgradeConfiguration(
                upgradeRequestHead: request,
                upgraders: [upgrader],
                notUpgradingCompletionHandler: { _ in channel.eventLoop.makeSucceededFuture(.notUpgraded) }
            )
            return try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                configuration: .init(upgradeConfiguration: clientUpgrade)
            )
        }
    }
    return try await upgrade.get()
}

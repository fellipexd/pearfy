import Crypto
import Foundation
import PearfyGameServer
import PearfyGameServerTransport

private struct Arguments {
    private let values: [String: String]

    init(_ arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), index + 1 < arguments.count, values[key] == nil else {
                throw LoadBenchError.usage
            }
            values[key] = arguments[index + 1]
            index += 2
        }
        self.values = values
    }

    func string(_ key: String) throws -> String {
        guard let value = values[key], !value.isEmpty else { throw LoadBenchError.usage }
        return value
    }

    func integer(_ key: String) throws -> Int {
        guard let value = Int(try string(key)), value > 0 else { throw LoadBenchError.usage }
        return value
    }
}

private enum LoadBenchError: Error {
    case usage
    case malformedPayload
}

private struct Scenario: Codable {
    let name: String
    let mode: GameServerMode
    let transport: String
    let host: String
    let port: Int
    let offeredPlayers: Int
    let admittedPlayers: Int
    let rateHz: Int
    let payloadBytes: Int
    let durationSeconds: Int
    let tickets: [String]?
    let datagramPlayers: [DatagramPlayer]?
}

private struct DatagramPlayer: Codable {
    let playerID: String
    let channelID: String
    let secret: String
}

private struct InputMessage: Decodable {
    let sequence: UInt64
}

private struct Acknowledgement: Encodable {
    let sequence: UInt64
    let accepted: Bool
}

private struct SimulationStats: Encodable {
    let tick: UInt64
    let acceptingInput: Bool
    let queuedInputCount: Int
    let queuedInputBytes: Int
    let acceptedInputCount: UInt64
    let capacityRejectionCount: UInt64
    let oversizedInputRejectionCount: UInt64
    let staleInputRejectionCount: UInt64
}

private struct DriverStats: Encodable {
    let running: Bool
    let failed: Bool
    let overloaded: Bool
    let completedTicks: UInt64
    let overrunCount: UInt64
    let consecutiveOverrunCount: Int
    let tickAdvanceFailureCount: UInt64
    let handlerFailureCount: UInt64
    let lastTickDurationNanoseconds: UInt64
}

private struct ServerStats: Encodable {
    let scenario: String
    let mode: GameServerMode
    let transport: String
    let offeredPlayers: Int
    let admittedPlayers: Int
    let listenerPort: Int
    let setupMilliseconds: Double
    let uptimeMilliseconds: Double
    let messagesReceived: UInt64
    let acceptedInputs: UInt64
    let rejectedInputs: UInt64
    let requestBytes: UInt64
    let responseBytes: UInt64
    let simulation: SimulationStats
    let driver: DriverStats
}

private final class Counters: @unchecked Sendable {
    private let lock = NSLock()
    private var received: UInt64 = 0
    private var accepted: UInt64 = 0
    private var rejected: UInt64 = 0
    private var requestBytes: UInt64 = 0
    private var responseBytes: UInt64 = 0
    private var ticks: UInt64 = 0
    private var tickInputs: UInt64 = 0

    func recordInput(bytesIn: Int, bytesOut: Int, accepted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        received &+= 1
        if accepted { self.accepted &+= 1 } else { rejected &+= 1 }
        requestBytes &+= UInt64(max(0, bytesIn))
        responseBytes &+= UInt64(max(0, bytesOut))
    }

    func recordTick(_ tick: GameRealtimeTick) {
        lock.lock()
        defer { lock.unlock() }
        ticks &+= 1
        tickInputs &+= UInt64(tick.acceptedInputs.count)
    }

    func snapshot() -> (received: UInt64, accepted: UInt64, rejected: UInt64, requestBytes: UInt64, responseBytes: UInt64, ticks: UInt64, tickInputs: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (received, accepted, rejected, requestBytes, responseBytes, ticks, tickInputs)
    }
}

@main
private struct LoadBenchServer {
    static func main() async throws {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("loadbench server failed: \(error)\n".utf8))
            throw error
        }
    }

    private static func run() async throws {
        let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
        let scenarioName = try args.string("--scenario")
        let mode = try GameServerMode(rawValue: args.string("--mode")).unwrap(or: LoadBenchError.usage)
        let transport = try args.string("--transport")
        let targetPlayers = try args.integer("--players")
        let rateHz = try args.integer("--rate")
        let payloadBytes = try args.integer("--payload")
        let duration = try args.integer("--duration")
        let profileURL = URL(fileURLWithPath: try args.string("--template"))
        let endpointURL = URL(fileURLWithPath: try args.string("--endpoint"))
        let clientURL = URL(fileURLWithPath: try args.string("--client-config"))
        let statsURL = URL(fileURLWithPath: try args.string("--stats"))
        let certificatePath = try args.string("--certificate")
        let privateKeyPath = try args.string("--private-key")

        let profileData = try Data(contentsOf: profileURL)
        let profile = try JSONDecoder().decode(GameServerModeProfile.self, from: profileData)
        guard profile.mode == mode, payloadBytes <= profile.resourceLimits.maximumMessageBytes,
              rateHz <= profile.resourceLimits.maximumMessagesPerSecondPerPlayer,
              transport == "websocket" || transport == "udp" else { throw LoadBenchError.usage }

        let setupStart = Date()
        let sessionID = UUID()
        let signingKey = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let authority = try GameSessionTicketAuthority(
            configuration: try GameServerConfiguration(maximumActiveTickets: max(10_000, targetPlayers + 1)),
            signingKey: signingKey
        )
        let simulation = try profile.makeRealtimeSimulation()
        let counters = Counters()
        let driver = try profile.makeRealtimeFixedStepDriver(simulation: simulation) { tick in
            counters.recordTick(tick)
        }
        _ = await driver.start()

        let host = "127.0.0.1"
        let capacity = profile.resourceLimits.maximumSessions
        let admittedPlayers = min(targetPlayers, capacity)
        let port: Int
        var setupMilliseconds = 0.0
        var servingStart = Date()
        let clientConfiguration: Scenario

        if transport == "websocket" {
            let tickets = try await issueTickets(
                count: admittedPlayers,
                sessionID: sessionID,
                authority: authority
            )
            var playersByTicket: [String: UUID] = [:]
            for (playerID, ticket) in tickets { playersByTicket[ticket.value] = playerID }
            let authenticatedPlayers = playersByTicket

            let gateway = GameServerWebSocketGateway(
                configuration: try GameServerWebSocketConfiguration(
                    host: host,
                    port: 0,
                    certificatePath: certificatePath,
                    privateKeyPath: privateKeyPath,
                    maximumConnections: capacity,
                    maximumMessageBytes: profile.resourceLimits.maximumMessageBytes,
                    maximumBufferedFramesPerConnection: 4,
                    maximumAggregateBufferedPayloadBytes: max(1_048_576, capacity * profile.resourceLimits.maximumMessageBytes * 7),
                    maximumMessagesPerSecondPerConnection: profile.resourceLimits.maximumMessagesPerSecondPerPlayer
                ),
                authorize: { bearerToken in
                    guard let playerID = authenticatedPlayers[bearerToken] else { return nil }
                    return await authority.authenticate(
                        GameSessionTicket(value: bearerToken),
                        sessionID: sessionID,
                        playerID: playerID,
                        protocolVersion: 1
                    )
                },
                onMessage: { principal, payload in
                    let accepted: Bool
                    if let input = try? JSONDecoder().decode(InputMessage.self, from: payload) {
                        do {
                            try await simulation.enqueue(GameRealtimeInput(
                                playerID: principal.playerID,
                                clientSequence: input.sequence,
                                payload: payload
                            ))
                            accepted = true
                        } catch {
                            accepted = false
                        }
                    } else {
                        accepted = false
                    }
                    let response = try JSONEncoder().encode(Acknowledgement(
                        sequence: (try? JSONDecoder().decode(InputMessage.self, from: payload).sequence) ?? 0,
                        accepted: accepted
                    ))
                    counters.recordInput(bytesIn: payload.count, bytesOut: response.count, accepted: accepted)
                    return response
                }
            )
            try await gateway.start()
            guard let boundPort = await gateway.boundPort() else { throw LoadBenchError.usage }
            port = boundPort
            clientConfiguration = Scenario(
                name: scenarioName,
                mode: mode,
                transport: transport,
                host: host,
                port: port,
                offeredPlayers: targetPlayers,
                admittedPlayers: admittedPlayers,
                rateHz: rateHz,
                payloadBytes: payloadBytes,
                durationSeconds: duration,
                tickets: tickets.map { $0.1.value },
                datagramPlayers: nil
            )
            try writeJSON(clientConfiguration, to: clientURL)
            try writeJSON(clientConfiguration, to: endpointURL)
            servingStart = Date()
            setupMilliseconds = servingStart.timeIntervalSince(setupStart) * 1_000
            FileHandle.standardOutput.write(Data("READY scenario=\(scenarioName) transport=websocket port=\(port) capacity=\(capacity)\n".utf8))

            while readLine() != "stop" {}
            try await gateway.stop()
        } else {
            let configuration = try GameServerUDPConfiguration(
                host: host,
                port: 0,
                maximumSessions: capacity,
                maximumDatagramBytes: 1_200,
                maximumPacketsPerSecond: max(100_000, admittedPlayers * rateHz + max(0, targetPlayers - admittedPlayers)),
                maximumPacketsPerSecondPerSession: profile.resourceLimits.maximumMessagesPerSecondPerPlayer
            )
            let server = GameServerUDPServer(configuration: configuration) { principal, payload in
                guard payload.count >= 9 else { return nil }
                let sequence = payload.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                let accepted: Bool
                do {
                    try await simulation.enqueue(GameRealtimeInput(
                        playerID: principal.playerID,
                        clientSequence: sequence,
                        payload: payload
                    ))
                    accepted = true
                } catch {
                    accepted = false
                }
                guard payload[8] == 1 else {
                    counters.recordInput(bytesIn: payload.count, bytesOut: 0, accepted: accepted)
                    return nil
                }
                var response = Data([accepted ? 1 : 0])
                var bigEndian = sequence.bigEndian
                withUnsafeBytes(of: &bigEndian) { response.append(contentsOf: $0) }
                counters.recordInput(bytesIn: payload.count, bytesOut: response.count, accepted: accepted)
                return response
            }
            let admission = try GameServerUDPAdmissionManager(
                ticketAuthority: authority,
                server: server,
                maximumPayloadBytes: configuration.maximumPayloadBytes
            )
            try await server.start()
            guard let boundPort = await server.boundPort() else { throw LoadBenchError.usage }
            port = boundPort

            var datagramPlayers: [DatagramPlayer] = []
            datagramPlayers.reserveCapacity(admittedPlayers)
            for (playerID, ticket) in try await issueTickets(count: admittedPlayers, sessionID: sessionID, authority: authority) {
                let credentials = try await admission.admit(
                    ticket: ticket,
                    sessionID: sessionID,
                    playerID: playerID,
                    protocolVersion: 1
                )
                let secret = credentials.sessionSecret.withUnsafeBytes { Data($0).base64EncodedString() }
                datagramPlayers.append(DatagramPlayer(
                    playerID: playerID.uuidString,
                    channelID: credentials.channelID.uuidString,
                    secret: secret
                ))
            }
            clientConfiguration = Scenario(
                name: scenarioName,
                mode: mode,
                transport: transport,
                host: host,
                port: port,
                offeredPlayers: targetPlayers,
                admittedPlayers: admittedPlayers,
                rateHz: rateHz,
                payloadBytes: payloadBytes,
                durationSeconds: duration,
                tickets: nil,
                datagramPlayers: datagramPlayers
            )
            try writeJSON(clientConfiguration, to: clientURL)
            try writeJSON(clientConfiguration, to: endpointURL)
            servingStart = Date()
            setupMilliseconds = servingStart.timeIntervalSince(setupStart) * 1_000
            FileHandle.standardOutput.write(Data("READY scenario=\(scenarioName) transport=udp port=\(port) capacity=\(capacity) admitted=\(admittedPlayers)\n".utf8))

            while readLine() != "stop" {}
            try await server.stop()
        }

        await driver.stop()
        let inputMetrics = await simulation.metrics()
        let driverMetrics = await driver.metrics()
        let totals = counters.snapshot()
        try writeJSON(ServerStats(
            scenario: scenarioName,
            mode: mode,
            transport: transport,
            offeredPlayers: targetPlayers,
            admittedPlayers: admittedPlayers,
            listenerPort: port,
            setupMilliseconds: setupMilliseconds,
            uptimeMilliseconds: Date().timeIntervalSince(servingStart) * 1_000,
            messagesReceived: totals.received,
            acceptedInputs: totals.accepted,
            rejectedInputs: totals.rejected,
            requestBytes: totals.requestBytes,
            responseBytes: totals.responseBytes,
            simulation: SimulationStats(
                tick: inputMetrics.currentTick,
                acceptingInput: inputMetrics.isAcceptingInput,
                queuedInputCount: inputMetrics.queuedInputCount,
                queuedInputBytes: inputMetrics.queuedInputBytes,
                acceptedInputCount: inputMetrics.acceptedInputCount,
                capacityRejectionCount: inputMetrics.capacityRejectionCount,
                oversizedInputRejectionCount: inputMetrics.oversizedInputRejectionCount,
                staleInputRejectionCount: inputMetrics.staleInputRejectionCount
            ),
            driver: DriverStats(
                running: driverMetrics.isRunning,
                failed: driverMetrics.isFailed,
                overloaded: driverMetrics.isOverloaded,
                completedTicks: driverMetrics.completedTicks,
                overrunCount: driverMetrics.overrunCount,
                consecutiveOverrunCount: driverMetrics.consecutiveOverrunCount,
                tickAdvanceFailureCount: driverMetrics.tickAdvanceFailureCount,
                handlerFailureCount: driverMetrics.handlerFailureCount,
                lastTickDurationNanoseconds: driverMetrics.lastTickDurationNanoseconds
            )
        ), to: statsURL)
        FileHandle.standardOutput.write(Data("STOPPED scenario=\(scenarioName) messages=\(totals.received) ticks=\(driverMetrics.completedTicks) overruns=\(driverMetrics.overrunCount)\n".utf8))
    }

    private static func issueTickets(
        count: Int,
        sessionID: UUID,
        authority: GameSessionTicketAuthority
    ) async throws -> [(UUID, GameSessionTicket)] {
        var result: [(UUID, GameSessionTicket)] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            let playerID = UUID()
            result.append((playerID, try await authority.issue(sessionID: sessionID, playerID: playerID)))
        }
        return result
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }
}

private extension Optional {
    func unwrap(or error: Error) throws -> Wrapped {
        guard let self else { throw error }
        return self
    }
}

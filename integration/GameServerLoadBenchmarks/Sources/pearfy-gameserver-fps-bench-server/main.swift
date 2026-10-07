#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import PearfyGameServer
import PearfyGameServerRealtime
import PearfyGameServerTransport

private enum BenchError: Error {
    case usage
    case invalidInput
}

private struct Arguments {
    private let values: [String: String]

    init(_ values: [String]) throws {
        var parsed: [String: String] = [:]
        var index = 0
        while index < values.count {
            guard values[index].hasPrefix("--"), index + 1 < values.count,
                  parsed[values[index]] == nil else { throw BenchError.usage }
            parsed[values[index]] = values[index + 1]
            index += 2
        }
        self.values = parsed
    }

    func string(_ key: String) throws -> String {
        guard let value = values[key], !value.isEmpty else { throw BenchError.usage }
        return value
    }

    func integer(_ key: String) throws -> Int {
        guard let value = Int(try string(key)), value > 0 else { throw BenchError.usage }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard !value.isEmpty else { throw BenchError.usage }
        return value
    }

    func port(_ key: String) throws -> Int? {
        guard let rawValue = values[key] else { return nil }
        guard let value = Int(rawValue), (0...65_535).contains(value) else { throw BenchError.usage }
        return value
    }
}

private struct PlayerCredential: Codable, Sendable {
    let playerID: String
    let channelID: String
    let secret: String
    let matchIndex: Int
    let playerSlot: Int
}

private struct ClientConfig: Codable, Sendable {
    let scenario: String
    let mode: String
    let host: String
    let port: Int
    let offeredPlayers: Int
    let activePlayers: Int
    let matchSize: Int
    let matchCount: Int
    let matchPlayerCounts: [Int]
    let rateHz: Int
    let payloadBytes: Int
    let durationSeconds: Int
    let players: [PlayerCredential]
}

private struct MatchMetrics: Codable, Sendable {
    let matchIndex: Int
    let playerCount: Int
    let ticks: UInt64
    let overruns: UInt64
    let maxTickMilliseconds: Double
    let averageTickMilliseconds: Double
    let workerThreadCount: Int
    let workerThreadIDs: [UInt64]
    let inputsAccepted: UInt64
    let queueRejections: UInt64
    let shots: UInt64
    let hits: UInt64
    let damage: UInt64
    let eliminations: UInt64
    let wallCollisionBlocks: UInt64
    let zoneDamageEvents: UInt64
    let lootPickups: UInt64
    let aoisBuilt: UInt64
    let visibleEntitiesTotal: UInt64
    let replicatedStateBytes: UInt64
}

private struct ServerStats: Codable, Sendable {
    let scenario: String
    let templateMode: String
    let transport: String
    let offeredPlayers: Int
    let activePlayers: Int
    let matchSize: Int
    let matchCount: Int
    let matchPlayerCounts: [Int]
    let templateSessionLimit: Int
    let benchmarkSessionLimit: Int
    let benchmarkCapacityOverride: Bool
    let listenerMaximumPacketsPerSecond: Int
    let tickRateHz: Int
    let maximumInputsPerTick: Int
    let durationSeconds: Int
    let listenerPort: Int
    let setupMilliseconds: Double
    let uptimeMilliseconds: Double
    let inputsReceived: UInt64
    let inputsAccepted: UInt64
    let requestPayloadBytes: UInt64
    let responsePayloadBytes: UInt64
    let ticksTotal: UInt64
    let tickOverruns: UInt64
    let maxTickMilliseconds: Double
    let averageTickMilliseconds: Double
    let workerThreadCount: Int
    let matches: [MatchMetrics]
}

private final class NetworkCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var received: UInt64 = 0
    private var accepted: UInt64 = 0
    private var requestBytes: UInt64 = 0
    private var responseBytes: UInt64 = 0

    func record(inputBytes: Int, outputBytes: Int, accepted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        received &+= 1
        if accepted { self.accepted &+= 1 }
        requestBytes &+= UInt64(max(0, inputBytes))
        responseBytes &+= UInt64(max(0, outputBytes))
    }

    func snapshot() -> (received: UInt64, accepted: UInt64, requestBytes: UInt64, responseBytes: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (received, accepted, requestBytes, responseBytes)
    }
}

private actor SimulationControl {
    private var active = true
    private var started = false
    private var startedAt: Date?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func begin() {
        guard !started else { return }
        started = true
        startedAt = Date()
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    func waitForStart() async {
        guard active, !started else { return }
        await withCheckedContinuation { continuation in
            if !active || started { continuation.resume() }
            else { startWaiters.append(continuation) }
        }
    }

    func stop() {
        active = false
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    func isActive() -> Bool { active }

    func activeDurationMilliseconds() -> Double {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt) * 1_000
    }
}

private struct FPSInput: Sendable {
    let sequence: UInt64
    let flags: UInt8
    let moveX: Int8
    let moveY: Int8
    let aimError: UInt16
    let targetSlot: Int

    init?(payload: Data) {
        guard payload.count == 64 else { return nil }
        sequence = payload.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        flags = payload[9]
        moveX = Int8(bitPattern: payload[10])
        moveY = Int8(bitPattern: payload[11])
        aimError = UInt16(payload[12]) | (UInt16(payload[13]) << 8)
        targetSlot = Int(payload[14]) | (Int(payload[15]) << 8)
    }

    var isFiring: Bool { flags & 0x01 != 0 }
    var isInteracting: Bool { flags & 0x02 != 0 }
}

private struct WorldRect: Sendable {
    let minX: Int32
    let minY: Int32
    let maxX: Int32
    let maxY: Int32

    func contains(_ x: Int32, _ y: Int32) -> Bool {
        x >= minX && x <= maxX && y >= minY && y <= maxY
    }
}

private struct LootCache: Sendable {
    let x: Int32
    let y: Int32
    var available = true
}

private struct PlayerState: Sendable {
    let id: UUID
    let team: Int
    var x: Int32
    var y: Int32
    var revision: UInt64 = 1
    var health = 100
    var armor = 50
    var ammo = 30
    var cooldownTicks = 0
    var reloadTicks = 0
    var alive = true
    var kills = 0
}

private actor FPSMatchRuntime {
    private let index: Int
    private let rateHz: Int
    private let maximumInputsPerTick: Int
    private let playersByID: [UUID: Int]
    private let simulation: GameRealtimeSimulation
    private let interest: GameRealtimeInterestManager
    private let obstacles: [WorldRect]
    private var players: [PlayerState]
    private var loot: [LootCache]
    private var tick: UInt64 = 0
    private var tickDurationTotal: UInt64 = 0
    private var maxTickDuration: UInt64 = 0
    private var overruns: UInt64 = 0
    private var inputsAccepted: UInt64 = 0
    private var queueRejections: UInt64 = 0
    private var shots: UInt64 = 0
    private var hits: UInt64 = 0
    private var damage: UInt64 = 0
    private var eliminations: UInt64 = 0
    private var wallCollisionBlocks: UInt64 = 0
    private var zoneDamageEvents: UInt64 = 0
    private var lootPickups: UInt64 = 0
    private var aoisBuilt: UInt64 = 0
    private var visibleEntitiesTotal: UInt64 = 0
    private var replicatedStateBytes: UInt64 = 0
    private var workerThreads = Set<UInt64>()
    private let clock = ContinuousClock()

    init(
        index: Int,
        playerIDs: [UUID],
        rateHz: Int,
        maximumInputsPerTick: Int,
        maximumQueuedInputs: Int,
        maximumQueuedBytes: Int,
        maximumInputBytes: Int,
        maximumQueuedInputsPerPlayer: Int,
        maximumQueuedBytesPerPlayer: Int
    ) throws {
        self.index = index
        self.rateHz = rateHz
        self.maximumInputsPerTick = maximumInputsPerTick
        playersByID = Dictionary(uniqueKeysWithValues: playerIDs.enumerated().map { ($1, $0) })
        simulation = try GameRealtimeSimulation(
            maximumQueuedInputs: maximumQueuedInputs,
            maximumInputBytes: maximumInputBytes,
            maximumPlayers: max(1, playerIDs.count),
            maximumQueuedBytes: maximumQueuedBytes,
            maximumQueuedInputsPerPlayer: maximumQueuedInputsPerPlayer,
            maximumQueuedBytesPerPlayer: maximumQueuedBytesPerPlayer
        )
        interest = GameRealtimeInterestManager(configuration: try GameRealtimeInterestConfiguration(
            cellSize: 128,
            maximumRadiusCells: 16,
            maximumEntities: max(1, playerIDs.count),
            maximumEntityStateBytes: 64,
            maximumTotalStateBytes: max(64, playerIDs.count * 64),
            maximumQueryCandidates: max(1, playerIDs.count),
            maximumPageEntities: max(1, playerIDs.count),
            maximumPageBytes: max(64, playerIDs.count * 64)
        ))
        obstacles = Self.buildMapObstacles()
        players = playerIDs.enumerated().map { slot, playerID in
            Self.spawn(playerID: playerID, slot: slot, playerCount: playerIDs.count)
        }
        loot = Self.buildLootCaches(playerCount: playerIDs.count)
    }

    func initializeWorld() async {
        for player in players {
            _ = try? await interest.upsert(Self.entity(for: player))
        }
    }

    func submit(playerID: UUID, payload: Data) async -> Bool {
        guard let _ = playersByID[playerID], let input = FPSInput(payload: payload) else {
            queueRejections &+= 1
            return false
        }
        do {
            try await simulation.enqueue(GameRealtimeInput(playerID: playerID, clientSequence: input.sequence, payload: payload))
            inputsAccepted &+= 1
            return true
        } catch {
            queueRejections &+= 1
            return false
        }
    }

    func runLoop(control: SimulationControl) async {
        await control.waitForStart()
        guard await control.isActive() else { return }
        let period = Duration.nanoseconds(Int64(1_000_000_000 / rateHz))
        var deadline = clock.now
        while await control.isActive(), !Task.isCancelled {
            deadline = deadline.advanced(by: period)
            do { try await clock.sleep(until: deadline, tolerance: .milliseconds(1)) }
            catch { break }
            guard await control.isActive(), !Task.isCancelled else { break }
            let start = DispatchTime.now().uptimeNanoseconds
            await advanceTick()
            if tick > 0, tick.isMultiple(of: 3) { await buildAOISnapshots() }
            let elapsed = DispatchTime.now().uptimeNanoseconds &- start
            tickDurationTotal &+= elapsed
            maxTickDuration = max(maxTickDuration, elapsed)
            workerThreads.insert(Self.currentThreadID())
            if elapsed > UInt64(1_000_000_000 / rateHz) {
                overruns &+= 1
                deadline = clock.now
            }
        }
    }

    func metrics() -> MatchMetrics {
        MatchMetrics(
            matchIndex: index,
            playerCount: players.count,
            ticks: tick,
            overruns: overruns,
            maxTickMilliseconds: Double(maxTickDuration) / 1_000_000,
            averageTickMilliseconds: tick == 0 ? 0 : Double(tickDurationTotal) / Double(tick) / 1_000_000,
            workerThreadCount: workerThreads.count,
            workerThreadIDs: workerThreads.sorted(),
            inputsAccepted: inputsAccepted,
            queueRejections: queueRejections,
            shots: shots,
            hits: hits,
            damage: damage,
            eliminations: eliminations,
            wallCollisionBlocks: wallCollisionBlocks,
            zoneDamageEvents: zoneDamageEvents,
            lootPickups: lootPickups,
            aoisBuilt: aoisBuilt,
            visibleEntitiesTotal: visibleEntitiesTotal,
            replicatedStateBytes: replicatedStateBytes
        )
    }

    private func advanceTick() async {
        do {
            let work = try await simulation.advanceTick(maximumInputs: maximumInputsPerTick)
            tick = work.tick
            for queued in work.acceptedInputs {
                guard let input = FPSInput(payload: queued.payload), let slot = playersByID[queued.playerID] else { continue }
                apply(input, to: slot)
            }
        } catch {
            queueRejections &+= 1
        }

        if tick > 0, tick.isMultiple(of: 60) { applySafeZoneDamage() }
        for player in players {
            _ = try? await interest.upsert(Self.entity(for: player))
        }
    }

    private func apply(_ input: FPSInput, to slot: Int) {
        guard players.indices.contains(slot), players[slot].alive else { return }
        var player = players[slot]
        if player.cooldownTicks > 0 { player.cooldownTicks -= 1 }
        if player.reloadTicks > 0 {
            player.reloadTicks -= 1
            if player.reloadTicks == 0 { player.ammo = 30 }
        }

        let nextX = min(4_080, max(16, player.x + Int32(input.moveX) * 4))
        let nextY = min(4_080, max(16, player.y + Int32(input.moveY) * 4))
        if obstacles.contains(where: { $0.contains(nextX, nextY) }) {
            wallCollisionBlocks &+= 1
        } else {
            player.x = nextX
            player.y = nextY
        }

        if input.isInteracting { collectLoot(for: &player) }
        player.revision &+= 1
        players[slot] = player
        if input.isFiring { fire(from: slot, target: input.targetSlot, aimError: input.aimError) }
    }

    private func fire(from shooterSlot: Int, target targetSlot: Int, aimError: UInt16) {
        guard players.indices.contains(shooterSlot) else { return }
        var shooter = players[shooterSlot]
        guard shooter.alive, shooter.cooldownTicks == 0, shooter.reloadTicks == 0 else { return }
        if shooter.ammo == 0 {
            shooter.reloadTicks = 90
            players[shooterSlot] = shooter
            return
        }
        shooter.ammo -= 1
        shooter.cooldownTicks = 6
        players[shooterSlot] = shooter
        shots &+= 1

        guard players.indices.contains(targetSlot), targetSlot != shooterSlot else { return }
        var target = players[targetSlot]
        guard target.alive, target.team != shooter.team, aimError <= 300 else { return }
        let dx = Int64(target.x - shooter.x)
        let dy = Int64(target.y - shooter.y)
        guard dx * dx + dy * dy <= 700 * 700,
              !hasLineOfSightBlock(fromX: shooter.x, fromY: shooter.y, toX: target.x, toY: target.y) else { return }

        hits &+= 1
        var hitDamage = 35
        let absorbed = min(target.armor, hitDamage * 2 / 3)
        target.armor -= absorbed
        hitDamage -= absorbed
        target.health = max(0, target.health - hitDamage)
        damage &+= 35
        target.revision &+= 1
        if target.health == 0 {
            target.alive = false
            shooter.kills += 1
            eliminations &+= 1
        }
        players[targetSlot] = target
        players[shooterSlot] = shooter
    }

    private func collectLoot(for player: inout PlayerState) {
        for index in loot.indices where loot[index].available {
            let dx = Int64(loot[index].x - player.x)
            let dy = Int64(loot[index].y - player.y)
            guard dx * dx + dy * dy <= 100 * 100 else { continue }
            loot[index].available = false
            player.ammo = min(30, player.ammo + 12)
            player.armor = min(100, player.armor + 20)
            lootPickups &+= 1
            return
        }
    }

    private func applySafeZoneDamage() {
        let radius = max(700, 1_100 - Int32(min(tick / 60, 40)) * 30)
        for index in players.indices where players[index].alive {
            var player = players[index]
            let dx = Int64(player.x - 2_048)
            let dy = Int64(player.y - 2_048)
            guard dx * dx + dy * dy > Int64(radius) * Int64(radius) else { continue }
            player.health = max(0, player.health - 5)
            player.revision &+= 1
            zoneDamageEvents &+= 1
            if player.health == 0 { player.alive = false; eliminations &+= 1 }
            players[index] = player
        }
    }

    private func buildAOISnapshots() async {
        for player in players where player.alive {
            do {
                let page = try await interest.snapshot(
                    around: GameRealtimePosition(x: player.x, y: player.y),
                    radiusCells: 5,
                    limit: max(1, players.count)
                )
                aoisBuilt &+= 1
                visibleEntitiesTotal &+= UInt64(page.entities.count)
                replicatedStateBytes &+= UInt64(page.entities.reduce(0) { $0 + $1.state.count })
            } catch {
                // Count only successful, bounded AOI results in the report.
            }
        }
    }

    private func hasLineOfSightBlock(fromX x0: Int32, fromY y0: Int32, toX x1: Int32, toY y1: Int32) -> Bool {
        for step in 1...8 {
            let x = x0 + (x1 - x0) * Int32(step) / 9
            let y = y0 + (y1 - y0) * Int32(step) / 9
            if obstacles.contains(where: { $0.contains(x, y) }) { return true }
        }
        return false
    }

    private static func spawn(playerID: UUID, slot: Int, playerCount: Int) -> PlayerState {
        let team = slot / 4
        let teamCount = max(1, (playerCount + 3) / 4)
        let angle = Double(team) * (2 * Double.pi / Double(teamCount))
        let memberOffset = Int32((slot % 4) * 18 - 27)
        let ring = 1_050 + Int32((team * 37) % 180)
        let x = 2_048 + Int32(cos(angle) * Double(ring)) + memberOffset
        let y = 2_048 + Int32(sin(angle) * Double(ring)) - memberOffset
        return PlayerState(id: playerID, team: team, x: x, y: y)
    }

    private static func buildMapObstacles() -> [WorldRect] {
        (0..<72).map { index in
            let x = Int32(180 + (index * 733 % 3_550))
            let y = Int32(180 + (index * 1_117 % 3_550))
            let width = Int32(45 + (index * 31 % 95))
            let height = Int32(45 + (index * 47 % 105))
            return WorldRect(minX: x, minY: y, maxX: min(4_080, x + width), maxY: min(4_080, y + height))
        }
    }

    private static func buildLootCaches(playerCount: Int) -> [LootCache] {
        var caches: [LootCache] = []
        let teamCount = max(1, (playerCount + 3) / 4)
        caches.reserveCapacity(teamCount + 6)
        for team in 0..<teamCount {
            let angle = Double(team) * (2 * Double.pi / Double(teamCount))
            let ring = 1_050 + Int32((team * 37) % 180)
            caches.append(LootCache(
                x: 2_048 + Int32(cos(angle) * Double(ring)),
                y: 2_048 + Int32(sin(angle) * Double(ring))
            ))
        }
        for index in 0..<6 {
            let x = Int32(256 + (index * 887 % 3_584))
            let y = Int32(256 + (index * 1_201 % 3_584))
            caches.append(LootCache(x: x, y: y))
        }
        return caches
    }

    private static func entity(for player: PlayerState) -> GameRealtimeSpatialEntity {
        var state = Data([
            UInt8(clamping: player.health),
            UInt8(clamping: player.armor),
            UInt8(clamping: player.team),
            player.alive ? 1 : 0,
            UInt8(clamping: player.ammo)
        ])
        var revision = player.revision.bigEndian
        withUnsafeBytes(of: &revision) { state.append(contentsOf: $0) }
        return GameRealtimeSpatialEntity(
            id: player.id,
            revision: max(1, player.revision),
            position: GameRealtimePosition(x: player.x, y: player.y),
            state: state
        )
    }

    private static func currentThreadID() -> UInt64 {
#if canImport(Darwin)
        var threadID: UInt64 = 0
        _ = pthread_threadid_np(nil, &threadID)
        return threadID
#elseif canImport(Glibc)
        return UInt64(pthread_self())
#else
        return 0
#endif
    }
}

@main
private struct FPSBenchmarkServer {
    static func main() async throws {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("fps benchmark server failed: \(error)\n".utf8))
            throw error
        }
    }

    private static func run() async throws {
        let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
        let playerCount = try args.integer("--players")
        let matchSize = try args.integer("--match-size")
        let duration = try args.integer("--duration")
        let templateURL = URL(fileURLWithPath: try args.string("--template"))
        let clientURL = URL(fileURLWithPath: try args.string("--client-config"))
        let endpointURL = URL(fileURLWithPath: try args.string("--endpoint"))
        let statsURL = URL(fileURLWithPath: try args.string("--stats"))
        let bindHost = try args.optionalString("--bind-host") ?? "127.0.0.1"
        let clientHost = try args.optionalString("--client-host") ?? bindHost
        let requestedPort = try args.port("--port") ?? 0

        let profile = try JSONDecoder().decode(GameServerModeProfile.self, from: Data(contentsOf: templateURL))
        guard profile.mode == .high, let fixedStep = profile.fixedStep,
              matchSize == 120,
              playerCount <= 5_000,
              fixedStep.tickRateHz == 60,
              profile.resourceLimits.maximumMessageBytes >= 64 else { throw BenchError.usage }

        let setupStart = Date()
        let matchPlayerCounts = stride(from: 0, to: playerCount, by: matchSize).map { min(matchSize, playerCount - $0) }
        let matchCount = matchPlayerCounts.count
        let sharedQueueBudget = max(playerCount, fixedStep.maximumQueuedInputs)
        let queuesPerMatch = max(120, fixedStep.maximumQueuedInputs / matchCount)
        let bytesPerMatch = max(profile.resourceLimits.maximumMessageBytes * 120,
                                profile.resourceLimits.maximumQueuedBytes / matchCount)
        var matchPlayers: [[UUID]] = []
        for count in matchPlayerCounts {
            matchPlayers.append((0..<count).map { _ in UUID() })
        }
        let matches = try matchPlayers.enumerated().map { index, ids in
            try FPSMatchRuntime(
                index: index,
                playerIDs: ids,
                rateHz: fixedStep.tickRateHz,
                maximumInputsPerTick: fixedStep.maximumInputsPerTick,
                maximumQueuedInputs: min(queuesPerMatch, sharedQueueBudget),
                maximumQueuedBytes: bytesPerMatch,
                maximumInputBytes: profile.resourceLimits.maximumMessageBytes,
                maximumQueuedInputsPerPlayer: fixedStep.maximumQueuedInputsPerPlayer,
                maximumQueuedBytesPerPlayer: fixedStep.maximumQueuedBytesPerPlayer
            )
        }
        for match in matches { await match.initializeWorld() }

        let benchmarkSessionLimit = max(profile.resourceLimits.maximumSessions, playerCount)
        let packetRateBudget = max(100_000, playerCount * fixedStep.tickRateHz + 5_000)
        let udpConfiguration = try GameServerUDPConfiguration(
            host: bindHost,
            port: requestedPort,
            maximumSessions: benchmarkSessionLimit,
            maximumDatagramBytes: 1_200,
            maximumPacketsPerSecond: packetRateBudget,
            maximumPacketsPerSecondPerSession: profile.resourceLimits.maximumMessagesPerSecondPerPlayer
        )
        var playerBindings: [UUID: (matchIndex: Int, slot: Int)] = [:]
        for (matchIndex, ids) in matchPlayers.enumerated() {
            for (slot, playerID) in ids.enumerated() { playerBindings[playerID] = (matchIndex, slot) }
        }
        let playersByID = playerBindings
        let control = SimulationControl()
        let networkCounters = NetworkCounters()
        let gameplayServer = GameServerUDPServer(configuration: udpConfiguration) { principal, payload in
            guard payload.count == 64,
                  let binding = playersByID[principal.playerID],
                  matches.indices.contains(binding.matchIndex) else {
                networkCounters.record(inputBytes: payload.count, outputBytes: 0, accepted: false)
                return nil
            }
            await control.begin()
            let accepted = await matches[binding.matchIndex].submit(playerID: principal.playerID, payload: payload)
            guard payload[8] == 1 else {
                networkCounters.record(inputBytes: payload.count, outputBytes: 0, accepted: accepted)
                return nil
            }
            var response = Data([accepted ? 1 : 0])
            response.append(contentsOf: payload.prefix(8))
            networkCounters.record(inputBytes: payload.count, outputBytes: response.count, accepted: accepted)
            return response
        }
        let authority = try GameSessionTicketAuthority(
            configuration: try GameServerConfiguration(maximumActiveTickets: playerCount + 1),
            signingKey: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        )
        try await gameplayServer.start()
        guard let port = await gameplayServer.boundPort() else { throw BenchError.usage }
        let admission = try GameServerUDPAdmissionManager(
            ticketAuthority: authority,
            server: gameplayServer,
            maximumPayloadBytes: udpConfiguration.maximumPayloadBytes
        )
        let matchSessionIDs = matchPlayers.map { _ in UUID() }
        var credentials: [PlayerCredential] = []
        credentials.reserveCapacity(playerCount)
        for (matchIndex, ids) in matchPlayers.enumerated() {
            for (slot, playerID) in ids.enumerated() {
                let ticket = try await authority.issue(sessionID: matchSessionIDs[matchIndex], playerID: playerID)
                let channel = try await admission.admit(
                    ticket: ticket,
                    sessionID: matchSessionIDs[matchIndex],
                    playerID: playerID,
                    protocolVersion: 1
                )
                credentials.append(PlayerCredential(
                    playerID: playerID.uuidString,
                    channelID: channel.channelID.uuidString,
                    secret: channel.sessionSecret.withUnsafeBytes { Data($0).base64EncodedString() },
                    matchIndex: matchIndex,
                    playerSlot: slot
                ))
            }
        }

        let endpoint = ClientConfig(
            scenario: "fps-high-combat-map",
            mode: profile.mode.rawValue,
            host: clientHost,
            port: await gameplayServer.boundPort() ?? port,
            offeredPlayers: playerCount,
            activePlayers: playerCount,
            matchSize: matchSize,
            matchCount: matchCount,
            matchPlayerCounts: matchPlayerCounts,
            rateHz: fixedStep.tickRateHz,
            payloadBytes: 64,
            durationSeconds: duration,
            players: credentials
        )
        try writeJSON(endpoint, to: clientURL)
        try writeJSON(endpoint, to: endpointURL)
        let setupMilliseconds = Date().timeIntervalSince(setupStart) * 1_000
        FileHandle.standardOutput.write(Data("READY scenario=fps-high-combat-map players=\(playerCount) matches=\(matchCount) tick=\(fixedStep.tickRateHz) listen=\(bindHost):\(endpoint.port) client=\(clientHost):\(endpoint.port)\n".utf8))

        let tickTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for match in matches {
                    group.addTask { await match.runLoop(control: control) }
                }
            }
        }
        while readLine() != "stop" {}
        await control.stop()
        await tickTask.value
        try await gameplayServer.stop()

        let matchMetrics = await withTaskGroup(of: MatchMetrics.self, returning: [MatchMetrics].self) { group in
            for match in matches { group.addTask { await match.metrics() } }
            var result: [MatchMetrics] = []
            for await metric in group { result.append(metric) }
            return result.sorted { $0.matchIndex < $1.matchIndex }
        }
        let totals = networkCounters.snapshot()
        let tickTotal = matchMetrics.reduce(UInt64(0)) { $0 &+ $1.ticks }
        let tickDurationTotal = matchMetrics.reduce(0.0) { $0 + $1.averageTickMilliseconds * Double($1.ticks) }
        let stats = ServerStats(
            scenario: "fps-high-combat-map",
            templateMode: profile.mode.rawValue,
            transport: "authenticated-encrypted-udp-binary",
            offeredPlayers: playerCount,
            activePlayers: playerCount,
            matchSize: matchSize,
            matchCount: matchCount,
            matchPlayerCounts: matchPlayerCounts,
            templateSessionLimit: profile.resourceLimits.maximumSessions,
            benchmarkSessionLimit: benchmarkSessionLimit,
            benchmarkCapacityOverride: benchmarkSessionLimit > profile.resourceLimits.maximumSessions,
            listenerMaximumPacketsPerSecond: packetRateBudget,
            tickRateHz: fixedStep.tickRateHz,
            maximumInputsPerTick: fixedStep.maximumInputsPerTick,
            durationSeconds: duration,
            listenerPort: endpoint.port,
            setupMilliseconds: setupMilliseconds,
            uptimeMilliseconds: await control.activeDurationMilliseconds(),
            inputsReceived: totals.received,
            inputsAccepted: totals.accepted,
            requestPayloadBytes: totals.requestBytes,
            responsePayloadBytes: totals.responseBytes,
            ticksTotal: tickTotal,
            tickOverruns: matchMetrics.reduce(UInt64(0)) { $0 &+ $1.overruns },
            maxTickMilliseconds: matchMetrics.map(\.maxTickMilliseconds).max() ?? 0,
            averageTickMilliseconds: tickTotal == 0 ? 0 : tickDurationTotal / Double(tickTotal),
            workerThreadCount: Set(matchMetrics.flatMap(\.workerThreadIDs)).count,
            matches: matchMetrics
        )
        try writeJSON(stats, to: statsURL)
        FileHandle.standardOutput.write(Data("STOPPED scenario=fps-high-combat-map inputs=\(totals.received) accepted=\(totals.accepted) ticks=\(tickTotal) overruns=\(stats.tickOverruns)\n".utf8))
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

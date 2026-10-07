import Foundation
import PearfyCLIKit
@testable import PearfyGameServer
import PearfyGameServerDevKit
import PearfyDevKitUI
@testable import PearfyGameServerRedisRecovery
import PearfyWeb
import Testing

@Test func gameSessionTicketsAreBoundToSessionPlayerAndProtocol() async throws {
    let config = try GameServerConfiguration(supportedProtocolVersion: 3, ticketLifetime: 60)
    let authority = try GameSessionTicketAuthority(configuration: config, signingKey: Data(repeating: 7, count: 32))
    let sessionID = UUID()
    let playerID = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let ticket = try await authority.issue(sessionID: sessionID, playerID: playerID, now: now)

    #expect(await authority.authenticate(ticket, sessionID: sessionID, playerID: playerID, protocolVersion: 3, now: now) == GameSessionPrincipal(
        sessionID: sessionID,
        playerID: playerID,
        protocolVersion: 3
    ))
    #expect(await authority.authenticate(ticket, sessionID: UUID(), playerID: playerID, protocolVersion: 3, now: now) == nil)
    #expect(await authority.authenticate(ticket, sessionID: sessionID, playerID: UUID(), protocolVersion: 3, now: now) == nil)
    #expect(await authority.authenticate(ticket, sessionID: sessionID, playerID: playerID, protocolVersion: 2, now: now) == nil)
    #expect(!String(describing: ticket).contains(ticket.value))
}

@Test func gameSessionTicketsExpireRevokeAndEnforceCapacity() async throws {
    let config = try GameServerConfiguration(ticketLifetime: 10, maximumActiveTickets: 1)
    let authority = try GameSessionTicketAuthority(configuration: config, signingKey: Data(repeating: 9, count: 32))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionID = UUID()
    let playerID = UUID()
    let ticket = try await authority.issue(sessionID: sessionID, playerID: playerID, now: now)

    do {
        _ = try await authority.issue(sessionID: sessionID, playerID: UUID(), now: now)
        Issue.record("ticket capacity must be bounded")
    } catch {
        #expect(error as? GameServerError == .ticketCapacityReached)
    }

    #expect(await authority.authenticate(ticket, sessionID: sessionID, playerID: playerID, protocolVersion: 1, now: now.addingTimeInterval(10)) == nil)
    let revocable = try await authority.issue(sessionID: sessionID, playerID: playerID, now: now)
    #expect(await authority.revoke(revocable, now: now))
    #expect(await authority.authenticate(revocable, sessionID: sessionID, playerID: playerID, protocolVersion: 1, now: now) == nil)
    #expect(await authority.activeTicketCount == 0)
    _ = try await authority.issue(sessionID: sessionID, playerID: playerID, now: now)
}

@Test func gameServerConfigurationAndSessionOffersFailClosed() throws {
    #expect(throws: GameServerError.invalidConfiguration) { try GameServerConfiguration(supportedProtocolVersion: 0) }
    #expect(throws: GameServerError.invalidConfiguration) { try GameServerConfiguration(ticketLifetime: 3_601) }
    #expect(throws: GameServerError.invalidConfiguration) { try GameServerConfiguration(maximumActiveTickets: 0) }
    #expect(throws: GameServerError.invalidSigningKey) {
        try GameSessionTicketAuthority(configuration: GameServerConfiguration(), signingKey: Data(repeating: 0, count: 31))
    }

    let ticket = GameSessionTicket(value: "opaque")
    #expect(throws: GameServerError.invalidSessionOffer) {
        try GameSessionOffer(
            sessionID: UUID(), playerID: UUID(),
            gatewayURL: try #require(URL(string: "ws://game.example/sessions/abc")),
            protocolVersion: 1, ticket: ticket
        )
    }
    #expect(throws: GameServerError.invalidSessionOffer) {
        try GameSessionOffer(
            sessionID: UUID(), playerID: UUID(),
            gatewayURL: try #require(URL(string: "wss://game.example/sessions/abc?ticket=secret")),
            protocolVersion: 1, ticket: ticket
        )
    }
}

@Test func gameServerModuleIsOptionalInTheModuleRegistry() throws {
    let module = try PearfyModuleManager().module(named: "gameserver")
    #expect(module.available)
    #expect(module.implementationStatus == .partial)
    #expect(module.products == ["PearfyGameServer"])
    #expect(try PearfyModuleManager().planAdding("gameserver", to: ["http"]).productsToAdd == ["PearfyGameServer"])
}

@Test func gameServerRecoveryAndDevKitAdaptersAreIndependentOptionalProducts() throws {
    let manager = try PearfyModuleManager()
    let realtime = try manager.module(named: "gameserver-realtime")
    let recovery = try manager.module(named: "gameserver-redis-recovery")
    let dashboard = try manager.module(named: "gameserver-devkit")
    let transport = try manager.module(named: "gameserver-transport")
    let agones = try manager.module(named: "gameserver-agones")
    let postgres = try manager.module(named: "gameserver-postgres")
    let distributedMatchmaking = try manager.module(named: "gameserver-matchmaking-postgres")
    let distributedWorld = try manager.module(named: "gameserver-world-postgres")
    #expect(realtime.implementationStatus == .partial)
    #expect(realtime.products == ["PearfyGameServerRealtime"])
    #expect(try manager.planAdding("gameserver-realtime", to: ["gameserver"]).productsToAdd == ["PearfyGameServerRealtime"])
    #expect(recovery.implementationStatus == .partial)
    #expect(recovery.products == ["PearfyGameServerRedisRecovery"])
    #expect(dashboard.implementationStatus == .partial)
    #expect(dashboard.products == ["PearfyGameServerDevKit"])
    #expect(transport.implementationStatus == .partial)
    #expect(transport.products == ["PearfyGameServerTransport"])
    #expect(agones.implementationStatus == .partial)
    #expect(agones.products == ["PearfyGameServerAgones"])
    #expect(postgres.implementationStatus == .partial)
    #expect(postgres.products == ["PearfyGameServerPostgres"])
    #expect(distributedMatchmaking.implementationStatus == .partial)
    #expect(distributedMatchmaking.products == ["PearfyGameServerMatchmakingPostgres"])
    #expect(distributedWorld.implementationStatus == .partial)
    #expect(distributedWorld.products == ["PearfyGameServerWorldPostgres"])
    #expect(try manager.planAdding("gameserver-redis-recovery", to: ["gameserver", "redis"]).productsToAdd == ["PearfyGameServerRedisRecovery"])
    #expect(try manager.planAdding("gameserver-devkit", to: ["gameserver", "devkit-ui"]).productsToAdd == ["PearfyGameServerDevKit"])
    #expect(try manager.planAdding("gameserver-transport", to: ["gameserver"]).productsToAdd == ["PearfyGameServerTransport"])
    #expect(try manager.planAdding("gameserver-agones", to: ["gameserver", "cloud"]).productsToAdd == ["PearfyGameServerAgones"])
    #expect(try manager.planAdding("gameserver-postgres", to: ["gameserver", "postgres"]).productsToAdd == ["PearfyGameServerPostgres"])
    #expect(try manager.planAdding("gameserver-matchmaking-postgres", to: ["gameserver", "postgres"]).productsToAdd == ["PearfyGameServerMatchmakingPostgres"])
    #expect(try manager.planAdding("gameserver-world-postgres", to: ["gameserver", "postgres"]).productsToAdd == ["PearfyGameServerWorldPostgres"])
    #expect(try manager.planAdding("gameserver-turn-based", to: ["gameserver"]).productsToAdd == ["PearfyGameServerTurnBased"])
    #expect(try manager.planAdding("gameserver-turn-based-postgres", to: ["gameserver", "gameserver-turn-based", "postgres"]).productsToAdd == ["PearfyGameServerTurnBasedPostgres"])
    #expect(try manager.planAdding("gameserver-turn-based-redis", to: ["gameserver", "gameserver-turn-based", "gameserver-redis-recovery"]).productsToAdd == ["PearfyGameServerTurnBasedRedis"])
}

@Test func realtimeGameServerProfileInstallsGameServerContracts() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-game-profile-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let frameworkRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let projectRoot = root.appendingPathComponent("game-api", isDirectory: true)

    #expect(try await PearfyProjectLifecycleCommand.run(
        command: "init",
        arguments: ["game-api", "--profile", "realtime-game-server", "--path", projectRoot.path],
        projectRoot: root,
        frameworkRoot: frameworkRoot
    ) == 0)

    let versions = try #require(try PearfyModuleManager().projectModuleVersions(projectRoot: projectRoot))
    #expect(versions["gameserver"] == "workspace")
}

@Test func gameServerModePresetsExplainMemoryTransportAndSafeUDPDefault() throws {
    let light = GameServerModeProfile.preset(.light)
    let medium = GameServerModeProfile.preset(.medium)
    let high = GameServerModeProfile.preset(.high)

    #expect(light.realtimeTransport == "websocket-over-tls")
    #expect(light.memoryManagement == "swift-arc-default")
    #expect(medium.realtimeTransport == light.realtimeTransport)
    #expect(medium.memoryManagement.contains("ownership-oriented"))
    #expect(high.realtimeTransport == "udp-datagram")
    #expect(high.wireFormat == "binary")
    #expect(high.memoryManagement.contains("ownership-oriented"))
    #expect(!high.udpEnabled)
    #expect(high.udpRequiresSecureDatagramAdapter)
    #expect(light.resourceLimits.maximumSessions < medium.resourceLimits.maximumSessions)
    #expect(medium.resourceLimits.maximumSessions < high.resourceLimits.maximumSessions)
    #expect(light.fixedStep?.tickRateHz == 20 && light.fixedStep?.maximumInputsPerTick == 128)
    #expect(medium.fixedStep?.tickRateHz == 30 && medium.fixedStep?.maximumInputsPerTick == 1_024)
    #expect(high.fixedStep?.tickRateHz == 60 && high.fixedStep?.maximumInputsPerTick == 8_192)
    #expect(high.fixedStep?.maximumQueuedInputs == 65_536)
    #expect(high.fixedStep?.maximumQueuedInputsPerPlayer == 256)
    #expect(high.fixedStep?.maximumConsecutiveOverruns == 3)
}

@Test func highModeProfileBuildsItsBoundedRealtimeQueueAndDrainsAfterSaturation() async throws {
    let profile = GameServerModeProfile.preset(.high)
    let limits = try #require(profile.fixedStep)
    let simulation = try profile.makeRealtimeSimulation()
    let player = UUID()

    for sequence in 1...limits.maximumQueuedInputsPerPlayer {
        try await simulation.enqueue(GameRealtimeInput(
            playerID: player,
            clientSequence: UInt64(sequence),
            payload: Data([1])
        ))
    }
    do {
        try await simulation.enqueue(GameRealtimeInput(
            playerID: player,
            clientSequence: UInt64(limits.maximumQueuedInputsPerPlayer + 1),
            payload: Data([1])
        ))
        Issue.record("the high-mode per-player queue cap must reject excess input")
    } catch {
        #expect(error as? GameServerError == .capacityReached)
    }

    let full = await simulation.metrics()
    #expect(full.queuedInputCount == limits.maximumQueuedInputsPerPlayer)
    #expect(full.queuedInputBytes == limits.maximumQueuedInputsPerPlayer)
    let tick = try await simulation.advanceTick(maximumInputs: limits.maximumInputsPerTick)
    #expect(tick.acceptedInputs.count == limits.maximumQueuedInputsPerPlayer)
    let drained = await simulation.metrics()
    #expect(drained.queuedInputCount == 0 && drained.queuedInputBytes == 0)
    _ = try profile.makeRealtimeFixedStepDriver(simulation: simulation) { _ in }
}

@Test func gameRoomsEnforceCapacityInviteReconnectAndOwnershipTransfer() async throws {
    let manager = GameRoomManager(configuration: try GameRoomConfiguration(maximumRooms: 1, maximumMembersPerRoom: 2, reconnectGracePeriod: 30))
    let owner = UUID(), guest = UUID()
    let room = try await manager.create(ownerID: owner)
    do { _ = try await manager.create(ownerID: UUID()); Issue.record("room capacity must be bounded") }
    catch { #expect(error as? GameServerError == .capacityReached) }
    do { _ = try await manager.join(roomID: room.id, playerID: guest); Issue.record("private room requires invite") }
    catch { #expect(error as? GameServerError == .roomNotFoundOrUnauthorized) }
    let invite = try await manager.invite(roomID: room.id, by: owner, playerID: guest)
    let joined = try await manager.join(roomID: room.id, playerID: guest, invite: invite)
    #expect(joined.members.count == 2)
    try await manager.disconnect(roomID: room.id, playerID: owner)
    let rejoined = try await manager.join(roomID: room.id, playerID: owner)
    #expect(rejoined.members.count == 2)
    try await manager.leave(roomID: room.id, playerID: owner)
    #expect(await manager.room(id: room.id)?.ownerID == guest)
}

@Test func gameRoomReconnectGraceIsEnforcedWithoutWaitingForReaper() async throws {
    let manager = GameRoomManager(configuration: try GameRoomConfiguration(maximumMembersPerRoom: 2, reconnectGracePeriod: 10))
    let owner = UUID()
    let room = try await manager.create(ownerID: owner)
    let disconnectedAt = Date(timeIntervalSince1970: 1_800_000_000)
    try await manager.disconnect(roomID: room.id, playerID: owner, now: disconnectedAt)

    do {
        _ = try await manager.join(roomID: room.id, playerID: owner, now: disconnectedAt.addingTimeInterval(10))
        Issue.record("a reconnect at/after the grace deadline must be rejected")
    } catch {
        #expect(error as? GameServerError == .roomNotFoundOrUnauthorized)
    }
    #expect(await manager.room(id: room.id) == nil)
    #expect(await manager.roomCount == 0)
}

@Test func duplicateRoomDisconnectDoesNotExtendReconnectGrace() async throws {
    let manager = GameRoomManager(configuration: try GameRoomConfiguration(reconnectGracePeriod: 10))
    let owner = UUID()
    let room = try await manager.create(ownerID: owner)
    let firstDisconnect = Date(timeIntervalSince1970: 1_800_000_000)
    try await manager.disconnect(roomID: room.id, playerID: owner, now: firstDisconnect)
    try await manager.disconnect(roomID: room.id, playerID: owner, now: firstDisconnect.addingTimeInterval(8))

    do {
        _ = try await manager.join(roomID: room.id, playerID: owner, now: firstDisconnect.addingTimeInterval(10))
        Issue.record("a duplicate disconnect must not extend the original grace deadline")
    } catch {
        #expect(error as? GameServerError == .roomNotFoundOrUnauthorized)
    }
    #expect(await manager.room(id: room.id) == nil)
}

@Test func roomMutationReapsExpiredMemberBeforeCheckingCapacity() async throws {
    let manager = GameRoomManager(configuration: try GameRoomConfiguration(maximumMembersPerRoom: 2, reconnectGracePeriod: 5))
    let owner = UUID(), guest = UUID(), replacement = UUID()
    let room = try await manager.create(ownerID: owner)
    let invite = try await manager.invite(roomID: room.id, by: owner, playerID: guest)
    _ = try await manager.join(roomID: room.id, playerID: guest, invite: invite)
    let disconnectedAt = Date(timeIntervalSince1970: 1_800_000_000)
    try await manager.disconnect(roomID: room.id, playerID: guest, now: disconnectedAt)
    let replacementInvite = try await manager.invite(
        roomID: room.id,
        by: owner,
        playerID: replacement,
        now: disconnectedAt.addingTimeInterval(5)
    )
    let updated = try await manager.join(
        roomID: room.id,
        playerID: replacement,
        invite: replacementInvite,
        now: disconnectedAt.addingTimeInterval(5)
    )
    #expect(updated.members == [owner, replacement])
    #expect(updated.disconnectedUntil[guest] == nil)
}

@Test func roomReadsAndPublicDiscoveryExcludeExpiredMembersWithoutReaper() async throws {
    let manager = GameRoomManager(configuration: try GameRoomConfiguration(maximumMembersPerRoom: 2, reconnectGracePeriod: 5))
    let owner = UUID(), guest = UUID()
    let room = try await manager.create(ownerID: owner, visibility: .public)
    _ = try await manager.join(roomID: room.id, playerID: guest)
    let disconnectedAt = Date(timeIntervalSince1970: 1_800_000_000)
    try await manager.disconnect(roomID: room.id, playerID: guest, now: disconnectedAt)

    let readTime = disconnectedAt.addingTimeInterval(5)
    let snapshot = await manager.room(id: room.id, now: readTime)
    let listing = await manager.publicRooms(now: readTime)
    #expect(snapshot?.members == [owner])
    #expect(snapshot?.disconnectedUntil[guest] == nil)
    #expect(listing.total == 1)
    #expect(listing.rooms.first?.memberCount == 1)
}

@Test func fullRoomJoinDoesNotConsumePrivateInvitation() async throws {
    let manager = GameRoomManager(configuration: try GameRoomConfiguration(maximumMembersPerRoom: 3))
    let owner = UUID(), firstGuest = UUID(), secondGuest = UUID(), waitingGuest = UUID()
    let room = try await manager.create(ownerID: owner)
    let firstInvite = try await manager.invite(roomID: room.id, by: owner, playerID: firstGuest)
    let secondInvite = try await manager.invite(roomID: room.id, by: owner, playerID: secondGuest)
    let waitingInvite = try await manager.invite(roomID: room.id, by: owner, playerID: waitingGuest)
    _ = try await manager.join(roomID: room.id, playerID: firstGuest, invite: firstInvite)
    _ = try await manager.join(roomID: room.id, playerID: secondGuest, invite: secondInvite)

    do {
        _ = try await manager.join(roomID: room.id, playerID: waitingGuest, invite: waitingInvite)
        Issue.record("a full room must reject the join")
    } catch {
        #expect(error as? GameServerError == .roomFull)
    }
    try await manager.leave(roomID: room.id, playerID: firstGuest)
    #expect((try await manager.join(roomID: room.id, playerID: waitingGuest, invite: waitingInvite)).members.contains(waitingGuest))
}

@Test func gameRoomInvitationsAreBoundToPlayerSingleUseAndExpiring() async throws {
    let manager = GameRoomManager(configuration: try GameRoomConfiguration(maximumMembersPerRoom: 4, inviteLifetime: 10))
    let owner = UUID(), invited = UUID(), other = UUID(), expiredInvitee = UUID()
    let room = try await manager.create(ownerID: owner)
    let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let invite = try await manager.invite(roomID: room.id, by: owner, playerID: invited, now: issuedAt)

    do {
        _ = try await manager.join(roomID: room.id, playerID: other, invite: invite, now: issuedAt.addingTimeInterval(1))
        Issue.record("a private invite must be bound to its player")
    } catch {
        #expect(error as? GameServerError == .roomNotFoundOrUnauthorized)
    }
    _ = try await manager.join(roomID: room.id, playerID: invited, invite: invite, now: issuedAt.addingTimeInterval(1))
    do {
        _ = try await manager.join(roomID: room.id, playerID: other, invite: invite, now: issuedAt.addingTimeInterval(2))
        Issue.record("a consumed invite must not authorize another player")
    } catch {
        #expect(error as? GameServerError == .roomNotFoundOrUnauthorized)
    }

    let expiringInvite = try await manager.invite(roomID: room.id, by: owner, playerID: expiredInvitee, now: issuedAt)
    do {
        _ = try await manager.join(roomID: room.id, playerID: expiredInvitee, invite: expiringInvite, now: issuedAt.addingTimeInterval(10))
        Issue.record("an invite is expired at its deadline")
    } catch {
        #expect(error as? GameServerError == .roomNotFoundOrUnauthorized)
    }
}

@Test func gameRoomManagerBoundsOneThousandEphemeralRooms() async throws {
    let manager = GameRoomManager(configuration: try GameRoomConfiguration(maximumRooms: 1_000))
    var roomIDs: [UUID] = []
    roomIDs.reserveCapacity(1_000)
    for _ in 0..<1_000 {
        roomIDs.append(try await manager.create(ownerID: UUID()).id)
    }
    #expect(await manager.roomCount == 1_000)
    do {
        _ = try await manager.create(ownerID: UUID())
        Issue.record("room creation must stop at the configured cap")
    } catch {
        #expect(error as? GameServerError == .capacityReached)
    }
    for (index, roomID) in roomIDs.enumerated() {
        guard let room = await manager.room(id: roomID), let ownerID = room.members.first else {
            Issue.record("the newly-created room must remain addressable before disposal")
            continue
        }
        try await manager.leave(roomID: roomID, playerID: ownerID)
        if index == 999 { #expect(await manager.roomCount == 0) }
    }
}

@Test func publicRoomDiscoveryIsPagedAndDoesNotExposeMemberIdentities() async throws {
    let manager = GameRoomManager(configuration: try GameRoomConfiguration(maximumRooms: 4, maximumMembersPerRoom: 4))
    let privateRoom = try await manager.create(ownerID: UUID())
    let firstPublic = try await manager.create(ownerID: UUID(), visibility: .public)
    let secondPublic = try await manager.create(ownerID: UUID(), visibility: .public)
    let guestID = UUID()
    _ = try await manager.join(roomID: firstPublic.id, playerID: guestID)

    let firstPage = await manager.publicRooms(offset: 0, limit: 1)
    let secondPage = await manager.publicRooms(offset: 1, limit: 1)
    #expect(firstPage.total == 2 && firstPage.rooms.count == 1)
    #expect(secondPage.total == 2 && secondPage.rooms.count == 1)
    #expect(firstPage.rooms[0].id == firstPublic.id)
    #expect(secondPage.rooms[0].id == secondPublic.id)
    #expect(firstPage.rooms[0].memberCount == 2)
    #expect(firstPage.rooms[0].maximumMembers == 4)
    #expect(firstPage.rooms[0].id != privateRoom.id)
    #expect(await manager.publicRooms(offset: 2, limit: 100).rooms.isEmpty)
    #expect(!String(describing: firstPage.rooms).contains(guestID.uuidString))
}

@Test func gameCommandsAreIdempotentOrderedAndBounded() async throws {
    let processor = try GameCommandProcessor(initialState: Data("0".utf8), maximumEvents: 2, maximumStateBytes: 8)
    let player = UUID(), id = UUID()
    let reducer: GameCommandProcessor.Reducer = { state, _, command in
        let current = Int(String(decoding: state, as: UTF8.self)) ?? 0
        let increment = Int(String(decoding: command, as: UTF8.self)) ?? 0
        return Data(String(current + increment).utf8)
    }
    let first = try await processor.submit(commandID: id, playerID: player, command: Data("2".utf8), expectedRevision: 0, reducer: reducer)
    let duplicate = try await processor.submit(commandID: id, playerID: player, command: Data("2".utf8), reducer: reducer)
    guard case .applied(let appliedEvent) = first, case .duplicate(let duplicateEvent) = duplicate else {
        Issue.record("first submission applies once and repeated command is marked duplicate")
        return
    }
    #expect(appliedEvent == duplicateEvent)
    #expect(await processor.currentRevision == 1)
    do {
        _ = try await processor.submit(commandID: id, playerID: UUID(), command: Data("2".utf8), reducer: reducer)
        Issue.record("a command ID cannot be replayed by another player")
    } catch { #expect(error as? GameServerError == .commandIDConflict) }
    do {
        _ = try await processor.submit(commandID: id, playerID: player, command: Data("9".utf8), reducer: reducer)
        Issue.record("a command ID cannot be reused with different bytes")
    } catch { #expect(error as? GameServerError == .commandIDConflict) }
    #expect(await processor.currentRevision == 1)
    do { _ = try await processor.submit(commandID: UUID(), playerID: player, command: Data("1".utf8), expectedRevision: 0, reducer: reducer); Issue.record("stale revision must fail") }
    catch { #expect(error as? GameServerError == .revisionConflict(current: 1)) }
    #expect(await processor.checkpoint().state == Data("2".utf8))
}

@Test func gameCommandCheckpointReplaysDeterministicallyAndRestoresIdempotency() async throws {
    let reducer: GameCommandProcessor.Reducer = { state, _, command in
        let current = Int(String(decoding: state, as: UTF8.self)) ?? 0
        let increment = Int(String(decoding: command, as: UTF8.self)) ?? 0
        return Data(String(current + increment).utf8)
    }
    let playerID = UUID()
    let firstCommandID = UUID()
    let processor = try GameCommandProcessor(initialState: Data("0".utf8), maximumEvents: 4)
    _ = try await processor.submit(commandID: firstCommandID, playerID: playerID, command: Data("2".utf8), reducer: reducer)
    _ = try await processor.submit(commandID: UUID(), playerID: playerID, command: Data("3".utf8), reducer: reducer)
    let checkpoint = await processor.checkpoint()

    let restored = try GameCommandProcessor(replaying: checkpoint, from: Data("0".utf8), maximumEvents: 4, reducer: reducer)
    #expect(await restored.currentRevision == 2)
    #expect(await restored.checkpoint().state == Data("5".utf8))
    let duplicate = try await restored.submit(commandID: firstCommandID, playerID: playerID, command: Data("2".utf8), reducer: reducer)
    guard case .duplicate(let duplicateEvent) = duplicate else {
        Issue.record("the restored history must preserve command idempotency")
        return
    }
    #expect(duplicateEvent.sequence == 1)

    let corrupted = GameStateCheckpoint(revision: checkpoint.revision, state: Data("999".utf8), events: checkpoint.events)
    do {
        _ = try GameCommandProcessor(replaying: corrupted, from: Data("0".utf8), reducer: reducer)
        Issue.record("restore must reject a checkpoint that diverges from deterministic replay")
    } catch { #expect(error as? GameServerError == .invalidCheckpoint) }
}

@Test func realtimeQueueAndWorldRegistryApplyHardBoundsAndFencing() async throws {
    let simulation = try GameRealtimeSimulation(maximumQueuedInputs: 1, maximumInputBytes: 2)
    let player = UUID()
    try await simulation.enqueue(GameRealtimeInput(playerID: player, clientSequence: 1, payload: Data([1])))
    do { try await simulation.enqueue(GameRealtimeInput(playerID: player, clientSequence: 2, payload: Data([2]))); Issue.record("queue capacity must be bounded") }
    catch { #expect(error as? GameServerError == .capacityReached) }
    let tick = try await simulation.advanceTick(maximumInputs: 1)
    #expect(tick.tick == 1 && tick.acceptedInputs.count == 1)
    do { try await simulation.enqueue(GameRealtimeInput(playerID: player, clientSequence: 1, payload: Data([1]))); Issue.record("stale input must fail") }
    catch { #expect(error as? GameServerError == .staleInput) }
    let metrics = await simulation.metrics()
    #expect(metrics.currentTick == 1)
    #expect(metrics.queuedInputCount == 0 && metrics.queuedInputBytes == 0)
    #expect(metrics.acceptedInputCount == 1)
    #expect(metrics.capacityRejectionCount == 1)
    #expect(metrics.staleInputRejectionCount == 1)

    let world = GameWorldRegistry(configuration: try GameWorldConfiguration(maximumZones: 2, maximumEntitiesPerZone: 1))
    let zoneA = try await world.createZone(), zoneB = try await world.createZone()
    let entity = try await world.addEntity(zoneID: zoneA, state: Data([7]))
    let moved = try await world.transfer(entityID: entity.id, from: zoneA, to: zoneB, expectedEpoch: entity.fencingEpoch)
    let sourceEntities = await world.entities(in: zoneA)
    #expect(moved.zoneID == zoneB && sourceEntities.isEmpty)
    do { _ = try await world.transfer(entityID: entity.id, from: zoneB, to: zoneA, expectedEpoch: entity.fencingEpoch); Issue.record("old fence must fail") }
    catch { #expect(error as? GameServerError == .staleFence) }
}

@Test func realtimeQueueAppliesPerPlayerBudgetsAndPreservesCapacityForOthers() async throws {
    let simulation = try GameRealtimeSimulation(
        maximumQueuedInputs: 3,
        maximumInputBytes: 8,
        maximumPlayers: 3,
        maximumQueuedBytes: 16,
        maximumQueuedInputsPerPlayer: 1,
        maximumQueuedBytesPerPlayer: 8
    )
    let noisyPlayer = UUID()
    let otherPlayer = UUID()
    try await simulation.enqueue(GameRealtimeInput(playerID: noisyPlayer, clientSequence: 1, payload: Data(repeating: 1, count: 8)))

    do {
        try await simulation.enqueue(GameRealtimeInput(playerID: noisyPlayer, clientSequence: 2, payload: Data([2])))
        Issue.record("one player must not fill another player's queue budget")
    } catch {
        #expect(error as? GameServerError == .capacityReached)
    }

    try await simulation.enqueue(GameRealtimeInput(playerID: otherPlayer, clientSequence: 1, payload: Data([3])))
    #expect(await simulation.queuedInputCount == 2)
    #expect(await simulation.queuedInputBytes == 9)
    #expect(await simulation.queuedInputCount(for: noisyPlayer) == 1)
    #expect(await simulation.queuedInputBytes(for: noisyPlayer) == 8)
    #expect((await simulation.metrics()).capacityRejectionCount == 1)

    _ = try await simulation.advanceTick(maximumInputs: 2)
    #expect(await simulation.queuedInputCount == 0)
    #expect(await simulation.queuedInputBytes == 0)
    #expect(await simulation.queuedInputCount(for: noisyPlayer) == 0)
    #expect(await simulation.queuedInputBytes(for: otherPlayer) == 0)
}

@Test func realtimeQueueRejectsSustainedOverflowAndRecoversWithinConfiguredBounds() async throws {
    let simulation = try GameRealtimeSimulation(
        maximumQueuedInputs: 32,
        maximumInputBytes: 8,
        maximumPlayers: 1,
        maximumQueuedBytes: 256,
        maximumQueuedInputsPerPlayer: 32,
        maximumQueuedBytesPerPlayer: 256
    )
    let player = UUID()
    var accepted = 0
    var rejected = 0
    for sequence in 1...1_000 {
        do {
            try await simulation.enqueue(GameRealtimeInput(
                playerID: player,
                clientSequence: UInt64(sequence),
                payload: Data(repeating: 7, count: 8)
            ))
            accepted += 1
        } catch {
            #expect(error as? GameServerError == .capacityReached)
            rejected += 1
        }
        let metrics = await simulation.metrics()
        #expect(metrics.queuedInputCount <= 32)
        #expect(metrics.queuedInputBytes <= 256)
    }

    #expect(accepted == 32)
    #expect(rejected == 968)
    let tick = try await simulation.advanceTick(maximumInputs: 32)
    #expect(tick.acceptedInputs.count == 32)
    #expect(tick.acceptedInputs.allSatisfy { $0.payload.count == 8 })
    #expect(await simulation.queuedInputCount == 0)
    #expect(await simulation.queuedInputBytes == 0)

    try await simulation.enqueue(GameRealtimeInput(playerID: player, clientSequence: 1_001, payload: Data([1])))
    #expect(await simulation.queuedInputCount == 1)
    let metrics = await simulation.metrics()
    #expect(metrics.capacityRejectionCount == 968)
    #expect(metrics.acceptedInputCount == 33)
}

private struct FixedStepTickProbe: Sendable {
    let tick: UInt64
    let time: TimeInterval
}

private enum FixedStepHandlerFailure: Error {
    case expected
}

@Test func realtimeFixedStepDriverReanchorsAfterSlowTicksWithoutCatchUpBursts() async throws {
    let simulation = try GameRealtimeSimulation(maximumQueuedInputs: 8, maximumInputBytes: 8)
    let configuration = try GameRealtimeFixedStepConfiguration(
        tickRateHz: 50,
        maximumInputsPerTick: 4
    )
    let (stream, continuation) = AsyncStream<FixedStepTickProbe>.makeStream(bufferingPolicy: .bufferingNewest(4))
    let driver = GameRealtimeFixedStepDriver(simulation: simulation, configuration: configuration) { tick in
        if tick.tick == 1 { Thread.sleep(forTimeInterval: 0.1) }
        continuation.yield(FixedStepTickProbe(tick: tick.tick, time: Date.timeIntervalSinceReferenceDate))
    }
    #expect(await driver.start())
    #expect(!(await driver.start()))

    var iterator = stream.makeAsyncIterator()
    let first = try #require(await iterator.next())
    let second = try #require(await iterator.next())
    #expect(first.tick == 1 && second.tick == 2)
    #expect(second.time - first.time >= 0.015)

    let metrics = await driver.metrics()
    #expect(metrics.completedTicks == 2)
    #expect(metrics.overrunCount == 1)
    #expect(metrics.consecutiveOverrunCount == 0)
    #expect(!metrics.isOverloaded)
    #expect(metrics.lastTickDurationNanoseconds < 20_000_000)
    #expect(!metrics.isFailed)
    await driver.stop()
    continuation.finish()
    #expect(!(await driver.metrics()).isRunning)
}

@Test func realtimeFixedStepDriverFailsClosedAfterReducerFailure() async throws {
    let simulation = try GameRealtimeSimulation()
    let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let driver = GameRealtimeFixedStepDriver(
        simulation: simulation,
        configuration: try GameRealtimeFixedStepConfiguration(tickRateHz: 100)
    ) { _ in
        continuation.yield(true)
        throw FixedStepHandlerFailure.expected
    }
    #expect(await driver.start())
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == true)
    await driver.stop()
    continuation.finish()

    let metrics = await driver.metrics()
    #expect(!metrics.isRunning && metrics.isFailed)
    #expect(metrics.handlerFailureCount == 1)
    #expect(!metrics.isOverloaded)
    #expect(!(await driver.start()))
}

@Test func realtimeFixedStepDriverClosesAdmissionAfterSustainedOverruns() async throws {
    let simulation = try GameRealtimeSimulation(
        maximumQueuedInputs: 2,
        maximumInputBytes: 1,
        maximumPlayers: 1,
        maximumQueuedBytes: 2,
        maximumQueuedInputsPerPlayer: 2,
        maximumQueuedBytesPerPlayer: 2
    )
    let player = UUID()
    try await simulation.enqueue(GameRealtimeInput(playerID: player, clientSequence: 1, payload: Data([1])))
    try await simulation.enqueue(GameRealtimeInput(playerID: player, clientSequence: 2, payload: Data([1])))

    let (stream, continuation) = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(2))
    let driver = GameRealtimeFixedStepDriver(
        simulation: simulation,
        configuration: try GameRealtimeFixedStepConfiguration(
            tickRateHz: 50,
            maximumInputsPerTick: 1,
            maximumConsecutiveOverruns: 2
        )
    ) { tick in
        continuation.yield(tick.tick)
        Thread.sleep(forTimeInterval: 0.06)
    }
    #expect(await driver.start())
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == 1)
    #expect(await iterator.next() == 2)
    await driver.stop()
    continuation.finish()

    let driverMetrics = await driver.metrics()
    #expect(driverMetrics.isOverloaded && driverMetrics.isFailed)
    #expect(driverMetrics.overrunCount == 2)
    #expect(driverMetrics.consecutiveOverrunCount == 2)
    let pausedMetrics = await simulation.metrics()
    #expect(!pausedMetrics.isAcceptingInput)
    #expect(pausedMetrics.queuedInputCount == 0)
    do {
        try await simulation.enqueue(GameRealtimeInput(playerID: player, clientSequence: 3, payload: Data([1])))
        Issue.record("input admission must remain closed after sustained overruns")
    } catch {
        #expect(error as? GameServerError == .capacityReached)
    }

    try await simulation.resumeInputAdmission()
    #expect((await simulation.metrics()).isAcceptingInput)
    let recoveredDriver = GameRealtimeFixedStepDriver(simulation: simulation) { _ in }
    #expect(await recoveredDriver.start())
    await recoveredDriver.stop()
}

@Test func realtimeFixedStepConfigurationRejectsRatesAndWorkBudgetsOutsideBounds() throws {
    do {
        _ = try GameRealtimeFixedStepConfiguration(tickRateHz: 0)
        Issue.record("zero tick rate must fail configuration")
    } catch {
        #expect(error as? GameServerError == .invalidConfiguration)
    }
    do {
        _ = try GameRealtimeFixedStepConfiguration(maximumInputsPerTick: 100_001)
        Issue.record("per-tick input work must stay bounded")
    } catch {
        #expect(error as? GameServerError == .invalidConfiguration)
    }
    do {
        _ = try GameRealtimeFixedStepConfiguration(maximumConsecutiveOverruns: 0)
        Issue.record("the overload circuit-breaker threshold must be positive")
    } catch {
        #expect(error as? GameServerError == .invalidConfiguration)
    }
}

@Test func realtimeSimulationResumesFromRecoveredTickAndRejectsTickOverflow() async throws {
    let simulation = try GameRealtimeSimulation(initialTick: 41)
    #expect(await simulation.currentTick == 41)
    let resumed = try await simulation.advanceTick(maximumInputs: 1)
    #expect(resumed.tick == 42)

    let exhausted = try GameRealtimeSimulation(initialTick: .max)
    await #expect(throws: GameServerError.tickExhausted) {
        _ = try await exhausted.advanceTick(maximumInputs: 1)
    }
    #expect(await exhausted.currentTick == .max)
}

@Test func matchmakingKeepsPartiesTogetherAndCoopObjectivesAreIdempotentAndPrivate() async throws {
    let queue = GameMatchmakingQueue(configuration: try GameMatchmakingConfiguration(minimumPlayers: 2, maximumPlayers: 3, initialSkillWindow: 10))
    let party = GameMatchTicket(playerIDs: [UUID(), UUID()], mode: "coop", region: "sa-east", skill: 100)
    let solo = GameMatchTicket(playerIDs: [UUID()], mode: "coop", region: "sa-east", skill: 105)
    try await queue.enqueue(party); try await queue.enqueue(solo)
    let matches = await queue.findMatches()
    #expect(matches.count == 1)
    #expect(matches[0].ticketIDs == [party.id, solo.id])
    #expect(matches[0].playerIDs.count == 3)
    #expect(await queue.queuedEntryCount == 0)

    let first = UUID(), second = UUID(), command = UUID()
    let session = try GameCoopSession(objectives: ["evidence", "extract"])
    try await session.join(playerID: first); try await session.join(playerID: second); try await session.start()
    let completed = try await session.completeObjective("evidence", commandID: command, by: first, publicState: Data("found".utf8), privatePlayerState: Data("private-clue".utf8))
    let duplicateCompletion = try await session.completeObjective(
        "evidence", commandID: command, by: first, publicState: Data("found".utf8),
        privatePlayerState: Data("private-clue".utf8)
    )
    #expect(completed)
    #expect(!duplicateCompletion)
    let firstSnapshot = try await session.snapshot(for: first)
    let secondSnapshot = try await session.snapshot(for: second)
    #expect(firstSnapshot.privatePlayerState[first] == Data("private-clue".utf8))
    #expect(secondSnapshot.privatePlayerState.isEmpty)
    try await session.finish(extracted: true); try await session.close()
}

@Test func coopSessionBoundsCommandDedupeAndRejectsCommandIDReuse() async throws {
    #expect(throws: GameServerError.invalidConfiguration) {
        try GameCoopSession(maximumPlayers: 257, objectives: ["evidence"])
    }
    #expect(throws: GameServerError.invalidConfiguration) {
        try GameCoopSession(objectives: ["evidence"], maximumObjectives: 4_097)
    }
    let first = UUID(), second = UUID(), commandID = UUID()
    let session = try GameCoopSession(
        objectives: ["evidence", "extract"], maximumStateBytes: 10, maximumProcessedCommands: 1
    )
    try await session.join(playerID: first)
    try await session.join(playerID: second)
    try await session.start()
    let revisionBeforeCompletion = try await session.snapshot(for: first).revision

    do {
        _ = try await session.completeObjective(
            "evidence", commandID: commandID, by: first,
            publicState: Data("public".utf8), privatePlayerState: Data("private".utf8)
        )
        Issue.record("the aggregate public/private state budget must be enforced")
    } catch { #expect(error as? GameServerError == .stateTooLarge) }
    #expect(try await session.snapshot(for: first).revision == revisionBeforeCompletion)

    let accepted = try await session.completeObjective(
        "evidence", commandID: commandID, by: first,
        publicState: Data("pub".utf8), privatePlayerState: Data("priv".utf8)
    )
    #expect(accepted)
    #expect(try await session.completeObjective(
        "evidence", commandID: commandID, by: first,
        publicState: Data("pub".utf8), privatePlayerState: Data("priv".utf8)
    ) == false)
    do {
        _ = try await session.completeObjective(
            "evidence", commandID: commandID, by: second,
            publicState: Data("pub".utf8), privatePlayerState: Data("priv".utf8)
        )
        Issue.record("a command ID cannot be replayed by another player")
    } catch { #expect(error as? GameServerError == .commandIDConflict) }
    do {
        _ = try await session.completeObjective(
            "evidence", commandID: commandID, by: first,
            publicState: Data("bad".utf8), privatePlayerState: Data("priv".utf8)
        )
        Issue.record("a command ID cannot be replayed with different state bytes")
    } catch { #expect(error as? GameServerError == .commandIDConflict) }
    do {
        _ = try await session.completeObjective(
            "extract", commandID: UUID(), by: first,
            publicState: Data("next".utf8)
        )
        Issue.record("the command idempotency window must be bounded")
    } catch { #expect(error as? GameServerError == .historyCapacityReached) }

    let snapshot = try await session.snapshot(for: first)
    #expect(snapshot.revision == revisionBeforeCompletion + 1)
    #expect(snapshot.publicState == Data("pub".utf8))
    #expect(snapshot.privatePlayerState[first] == Data("priv".utf8))
    #expect(try await session.snapshot(for: second).privatePlayerState.isEmpty)
}

@Test func coopObjectivePrerequisitesAreValidatedAndEnforcedBeforeMutation() async throws {
    #expect(throws: GameServerError.invalidConfiguration) {
        try GameCoopSession(objectives: ["find", "escape"], objectivePrerequisites: ["escape": ["missing"]])
    }
    #expect(throws: GameServerError.invalidConfiguration) {
        try GameCoopSession(objectives: ["find", "escape"], objectivePrerequisites: ["find": ["escape"], "escape": ["find"]])
    }

    let player = UUID()
    let session = try GameCoopSession(
        objectives: ["find", "escape"],
        objectivePrerequisites: ["escape": ["find"]]
    )
    try await session.join(playerID: player)
    try await session.start()
    let revision = try await session.snapshot(for: player).revision
    do {
        _ = try await session.completeObjective("escape", commandID: UUID(), by: player, publicState: Data())
        Issue.record("dependent objective must wait for its prerequisite")
    } catch { #expect(error as? GameServerError == .objectivePrerequisitesIncomplete) }
    #expect(try await session.snapshot(for: player).revision == revision)
    #expect(try await session.snapshot(for: player).completedObjectives.isEmpty)

    #expect(try await session.completeObjective("find", commandID: UUID(), by: player, publicState: Data("found".utf8)))
    #expect(try await session.completeObjective("escape", commandID: UUID(), by: player, publicState: Data("escaped".utf8)))
    #expect(try await session.snapshot(for: player).completedObjectives == Set(["find", "escape"]))
}

@Test func coopSessionSeedProducesReplayableBackendDecisionSequence() async throws {
    let firstPlayer = UUID(), secondPlayer = UUID()
    let first = try GameCoopSession(objectives: ["mission"], deterministicSeed: 0xA11CE)
    let second = try GameCoopSession(objectives: ["mission"], deterministicSeed: 0xA11CE)
    try await first.join(playerID: firstPlayer)
    try await second.join(playerID: secondPlayer)
    try await first.start()
    try await second.start()
    var firstSequence: [UInt64] = [], secondSequence: [UInt64] = []
    for _ in 0..<8 {
        firstSequence.append(try await first.nextDeterministicValue())
        secondSequence.append(try await second.nextDeterministicValue())
    }
    #expect(firstSequence == secondSequence)
    let snapshot = try await first.snapshot(for: firstPlayer)
    #expect(snapshot.deterministicDrawCount == 8)
    #expect(snapshot.revision == 10)

    let unseeded = try GameCoopSession(objectives: ["mission"])
    try await unseeded.join(playerID: firstPlayer)
    try await unseeded.start()
    do {
        _ = try await unseeded.nextDeterministicValue()
        Issue.record("an unseeded session cannot generate deterministic values")
    } catch { #expect(error as? GameServerError == .invalidCoopTransition) }
}

@Test func coopObjectiveProgressIsMonotonicBoundedAndIdempotent() async throws {
    #expect(throws: GameServerError.invalidConfiguration) {
        try GameCoopSession(objectives: ["scan"], objectiveProgressTargets: ["unknown": 5])
    }
    #expect(throws: GameServerError.invalidConfiguration) {
        try GameCoopSession(objectives: ["scan"], objectiveProgressTargets: ["scan": 0])
    }

    let player = UUID()
    let session = try GameCoopSession(objectives: ["scan"], objectiveProgressTargets: ["scan": 5])
    try await session.join(playerID: player)
    try await session.start()
    do {
        _ = try await session.completeObjective("scan", commandID: UUID(), by: player, publicState: Data())
        Issue.record("an objective with a progress target cannot skip required progress")
    } catch { #expect(error as? GameServerError == .objectiveProgressIncomplete) }

    let progressCommand = UUID()
    #expect(try await session.recordObjectiveProgress(
        "scan", by: 2, commandID: progressCommand, playerID: player, publicState: Data("partial".utf8)
    ))
    #expect(!(try await session.recordObjectiveProgress(
        "scan", by: 2, commandID: progressCommand, playerID: player, publicState: Data("partial".utf8)
    )))
    do {
        _ = try await session.recordObjectiveProgress(
            "scan", by: 3, commandID: progressCommand, playerID: player, publicState: Data("partial".utf8)
        )
        Issue.record("a progress command ID cannot be reused with a different delta")
    } catch { #expect(error as? GameServerError == .commandIDConflict) }
    let partial = try await session.snapshot(for: player)
    #expect(partial.objectiveProgress == ["scan": 2])
    #expect(partial.completedObjectives.isEmpty)

    #expect(try await session.recordObjectiveProgress(
        "scan", by: 99, commandID: UUID(), playerID: player, publicState: Data("complete".utf8)
    ))
    let complete = try await session.snapshot(for: player)
    #expect(complete.objectiveProgress == ["scan": 5])
    #expect(complete.completedObjectives == Set(["scan"]))
}

@Test func coopNPCActionSchedulerIsOrderedBoundedAndClearedOnSessionEnd() async throws {
    let player = UUID()
    let session = try GameCoopSession(
        objectives: ["mission"], maximumQueuedNPCActions: 3, maximumNPCActionBytes: 4,
        maximumQueuedNPCActionBytes: 8, maximumNPCActionsPerBatch: 2, maximumProcessedNPCActions: 4
    )
    try await session.join(playerID: player)
    try await session.start()
    let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let laterID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    let first = GameCoopScheduledNPCAction(id: firstID, npcID: "haunt", dueTick: 1, payload: Data([1, 2]))
    let second = GameCoopScheduledNPCAction(id: secondID, npcID: "haunt", dueTick: 1, payload: Data([3, 4]))
    let later = GameCoopScheduledNPCAction(id: laterID, npcID: "haunt", dueTick: 2, payload: Data([5, 6]))
    #expect(try await session.scheduleNPCAction(first))
    #expect(!(try await session.scheduleNPCAction(first)))
    #expect(try await session.scheduleNPCAction(second))
    #expect(try await session.scheduleNPCAction(later))
    #expect(await session.queuedNPCActionCount == 3)
    #expect(await session.queuedNPCActionBytes == 6)
    do {
        _ = try await session.scheduleNPCAction(GameCoopScheduledNPCAction(npcID: "haunt", dueTick: 3, payload: Data()))
        Issue.record("the bounded scheduled-action queue must reject overflow")
    } catch { #expect(error as? GameServerError == .npcActionCapacityReached) }

    let firstBatch = try await session.advanceNPCSchedule(to: 1, maximumActions: 1)
    #expect(firstBatch.actions.map(\.id) == [firstID])
    #expect(await session.queuedNPCActionCount == 2)
    let secondBatch = try await session.advanceNPCSchedule(to: 1, maximumActions: 1)
    #expect(secondBatch.actions.map(\.id) == [secondID])
    let laterBatch = try await session.advanceNPCSchedule(to: 2)
    #expect(laterBatch.actions.map(\.id) == [laterID])
    #expect(await session.queuedNPCActionCount == 0)
    #expect(await session.queuedNPCActionBytes == 0)
    do {
        _ = try await session.scheduleNPCAction(first)
        Issue.record("a consumed action ID cannot be replayed into the scheduler")
    } catch { #expect(error as? GameServerError == .npcActionIDConflict) }

    let pending = GameCoopScheduledNPCAction(npcID: "haunt", dueTick: 3, payload: Data([7]))
    try await session.scheduleNPCAction(pending)
    try await session.finish(extracted: true)
    #expect(await session.queuedNPCActionCount == 0)
    do {
        _ = try await session.advanceNPCSchedule(to: 3)
        Issue.record("ended sessions cannot emit scheduled actions")
    } catch { #expect(error as? GameServerError == .invalidCoopTransition) }
}

@Test func coopNPCOutboxSurvivesCheckpointUntilActionsAreAcknowledged() async throws {
    let playerID = UUID()
    let session = try GameCoopSession(
        objectives: ["mission"], maximumQueuedNPCActions: 2, maximumNPCActionsPerBatch: 2
    )
    try await session.join(playerID: playerID)
    try await session.start()
    let action = GameCoopScheduledNPCAction(npcID: "warden", dueTick: 2, payload: Data("approach".utf8))
    try await session.scheduleNPCAction(action)

    let staged = try await session.stageNPCActions(to: 2)
    #expect(staged.actions == [action])
    #expect(await session.queuedNPCActionCount == 0)
    #expect(await session.pendingNPCDispatchCount == 1)
    #expect(try await session.pendingNPCActionBatch().actions == [action])

    let checkpoint = try await session.recoveryCheckpointData()
    let restored = try GameCoopSession(restoringCheckpoint: checkpoint)
    #expect(try await restored.pendingNPCActionBatch().actions == [action])
    do {
        try await restored.acknowledgeNPCActions([UUID()])
        Issue.record("unknown action IDs cannot be acknowledged")
    } catch { #expect(error as? GameServerError == .invalidNPCAction) }
    #expect(try await restored.acknowledgeNPCActions([action.id]) == 1)
    #expect(await restored.pendingNPCDispatchCount == 0)
    #expect(await restored.pendingNPCDispatchBytesCount == 0)
}

@Test func coopSessionRecoveryRestoresProgressSeedPrivateStateAndScheduledActions() async throws {
    let playerID = UUID()
    let sessionID = UUID()
    let progressCommand = UUID()
    let action = GameCoopScheduledNPCAction(npcID: "stalker", dueTick: 5, payload: Data("approach".utf8))
    let original = try GameCoopSession(
        sessionID: sessionID,
        objectives: ["evidence", "extract"],
        objectivePrerequisites: ["extract": ["evidence"]],
        objectiveProgressTargets: ["evidence": 5],
        deterministicSeed: 0xF13D
    )
    try await original.join(playerID: playerID)
    try await original.start()
    #expect(try await original.recordObjectiveProgress(
        "evidence", by: 2, commandID: progressCommand, playerID: playerID,
        publicState: Data("evidence-visible".utf8), privatePlayerState: Data("private-clue".utf8)
    ))
    _ = try await original.nextDeterministicValue()
    _ = try await original.nextDeterministicValue()
    #expect(try await original.scheduleNPCAction(action))

    let captured = try await original.recoveryCheckpoint()
    #expect(captured.sessionRevision == (try await original.snapshot(for: playerID).revision))
    let checkpoint = captured.data
    let restored = try GameCoopSession(restoringCheckpoint: checkpoint)
    #expect(try await restored.snapshot(for: playerID).revision == captured.sessionRevision)
    #expect(try await restored.snapshot(for: playerID).sessionID == sessionID)
    #expect(try await restored.snapshot(for: playerID).objectiveProgress == ["evidence": 2])
    #expect(try await restored.snapshot(for: playerID).privatePlayerState[playerID] == Data("private-clue".utf8))
    #expect(await restored.queuedNPCActionCount == 1)
    #expect(!(try await restored.recordObjectiveProgress(
        "evidence", by: 2, commandID: progressCommand, playerID: playerID,
        publicState: Data("evidence-visible".utf8), privatePlayerState: Data("private-clue".utf8)
    )))

    let expectedRandomValue = try await original.nextDeterministicValue()
    let restoredRandomValue = try await restored.nextDeterministicValue()
    #expect(restoredRandomValue == expectedRandomValue)
    let expectedActionBatch = try await original.advanceNPCSchedule(to: 5)
    let restoredActionBatch = try await restored.advanceNPCSchedule(to: 5)
    #expect(restoredActionBatch == expectedActionBatch)
    #expect(await restored.queuedNPCActionBytes == 0)

    #expect(try await restored.recordObjectiveProgress(
        "evidence", by: 3, commandID: UUID(), playerID: playerID,
        publicState: Data("evidence-complete".utf8), privatePlayerState: Data("private-clue".utf8)
    ))
    #expect(try await restored.snapshot(for: playerID).completedObjectives.contains("evidence"))

    #expect(throws: GameServerError.invalidCheckpoint) {
        try GameCoopSession(restoringCheckpoint: checkpoint, maximumCheckpointBytes: checkpoint.count - 1)
    }
    #expect(throws: GameServerError.invalidCheckpoint) {
        try GameCoopSession(restoringCheckpoint: Data("not-json".utf8))
    }
}

@Test func coopRecoveryCheckpointEncodingIsStableAcrossSetInsertionOrder() async throws {
    let sessionID = UUID()
    let firstPlayer = UUID()
    let secondPlayer = UUID()
    let first = try GameCoopSession(
        sessionID: sessionID,
        objectives: ["alpha", "beta"],
        deterministicSeed: 7
    )
    let second = try GameCoopSession(
        sessionID: sessionID,
        objectives: ["beta", "alpha"],
        deterministicSeed: 7
    )
    try await first.join(playerID: firstPlayer)
    try await first.join(playerID: secondPlayer)
    try await second.join(playerID: secondPlayer)
    try await second.join(playerID: firstPlayer)

    #expect(try await first.recoveryCheckpointData() == second.recoveryCheckpointData())
}

@Test func coopSessionReconnectGraceRejectsActionsUntilAuthenticatedResume() async throws {
    let playerID = UUID()
    let commandID = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let session = try GameCoopSession(
        objectives: ["evidence"],
        objectiveProgressTargets: ["evidence": 3]
    )
    try await session.join(playerID: playerID)
    try await session.start()
    #expect(try await session.recordObjectiveProgress(
        "evidence", by: 1, commandID: commandID, playerID: playerID,
        publicState: Data("visible".utf8), privatePlayerState: Data("private clue".utf8)
    ))

    let deadline = try await session.disconnect(playerID: playerID, gracePeriodMilliseconds: 1_000, now: now)
    #expect(deadline == now.addingTimeInterval(1))
    #expect(try await session.disconnect(playerID: playerID, gracePeriodMilliseconds: 20_000, now: now) == deadline)
    #expect(await session.connectedMemberCount == 0)
    #expect(await session.disconnectedMemberCount == 1)
    do {
        _ = try await session.snapshot(for: playerID)
        Issue.record("disconnected members cannot read session snapshots")
    } catch {
        #expect(error as? GameServerError == .coopMemberDisconnected)
    }
    do {
        _ = try await session.recordObjectiveProgress(
            "evidence", by: 1, commandID: commandID, playerID: playerID,
            publicState: Data("visible".utf8), privatePlayerState: Data("private clue".utf8)
        )
        Issue.record("disconnected members cannot submit gameplay actions")
    } catch {
        #expect(error as? GameServerError == .coopMemberDisconnected)
    }

    try await session.reconnect(playerID: playerID, now: deadline.addingTimeInterval(-0.001))
    let resumed = try await session.snapshot(for: playerID)
    #expect(resumed.privatePlayerState[playerID] == Data("private clue".utf8))
    #expect(!(try await session.recordObjectiveProgress(
        "evidence", by: 1, commandID: commandID, playerID: playerID,
        publicState: Data("visible".utf8), privatePlayerState: Data("private clue".utf8)
    )))
    #expect(await session.connectedMemberCount == 1)
}

@Test func coopSessionReconnectExpiryAbandonsMemberAndFailsWhenNobodyCanReturn() async throws {
    let playerID = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let session = try GameCoopSession(objectives: ["mission"])
    try await session.join(playerID: playerID)
    try await session.start()
    let deadline = try await session.disconnect(playerID: playerID, gracePeriodMilliseconds: 500, now: now)
    let checkpoint = try await session.recoveryCheckpoint()
    let restored = try GameCoopSession(restoringCheckpoint: checkpoint.data)
    #expect(await restored.disconnectedMemberCount == 1)
    do {
        try await restored.reconnect(playerID: playerID, now: deadline)
        Issue.record("reconnect at the deadline must expire without requiring a background reaper")
    } catch {
        #expect(error as? GameServerError == .coopReconnectExpired)
    }
    #expect(await restored.disconnectedMemberCount == 0)
    do {
        _ = try await restored.snapshot(for: playerID)
        Issue.record("abandoned members cannot read session snapshots")
    } catch {
        #expect(error as? GameServerError == .coopMemberAbandoned)
    }
    do {
        _ = try await restored.scheduleNPCAction(GameCoopScheduledNPCAction(npcID: "npc", dueTick: 1, payload: Data()))
        Issue.record("a session with no connected members must fail")
    } catch {
        #expect(error as? GameServerError == .invalidCoopTransition)
    }
}

@Test func coopSessionExpiresOneMemberWithoutFailingRemainingPlayers() async throws {
    let disconnectedPlayer = UUID()
    let remainingPlayer = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let session = try GameCoopSession(objectives: ["mission"])
    try await session.join(playerID: disconnectedPlayer)
    try await session.join(playerID: remainingPlayer)
    try await session.start()
    #expect(try await session.completeObjective(
        "mission", commandID: UUID(), by: disconnectedPlayer,
        publicState: Data("shared".utf8), privatePlayerState: Data("private".utf8)
    ))
    let deadline = try await session.disconnect(playerID: disconnectedPlayer, gracePeriodMilliseconds: 500, now: now)

    #expect(await session.expireDisconnectedMembers(now: deadline) == [disconnectedPlayer])
    #expect(await session.connectedMemberCount == 1)
    #expect(try await session.snapshot(for: remainingPlayer).phase == .active)
    #expect(try await session.snapshot(for: remainingPlayer).privatePlayerState.isEmpty)
    do {
        _ = try await session.snapshot(for: disconnectedPlayer)
        Issue.record("an expired member must lose snapshot access")
    } catch {
        #expect(error as? GameServerError == .coopMemberAbandoned)
    }

    try await session.abandon(playerID: remainingPlayer)
    do {
        _ = try await session.scheduleNPCAction(GameCoopScheduledNPCAction(npcID: "npc", dueTick: 1, payload: Data()))
        Issue.record("abandoning the last connected player must fail the session")
    } catch {
        #expect(error as? GameServerError == .invalidCoopTransition)
    }
}

@Test func coopSessionRecoveryStillReadsCheckpointsWithoutReconnectFields() async throws {
    let playerID = UUID()
    let session = try GameCoopSession(objectives: ["mission"])
    try await session.join(playerID: playerID)
    try await session.start()
    let current = try await session.recoveryCheckpoint()
    var envelope = try #require(JSONSerialization.jsonObject(with: current.data) as? [String: Any])
    envelope.removeValue(forKey: "disconnectedUntil")
    envelope.removeValue(forKey: "abandonedMembers")
    let legacyData = try JSONSerialization.data(withJSONObject: envelope)

    let restored = try GameCoopSession(restoringCheckpoint: legacyData)
    #expect(try await restored.snapshot(for: playerID).phase == .active)
    #expect(await restored.connectedMemberCount == 1)
}

@Test func gameStateManagerPersistsOffThreadAndDevKitPaginatesProtectedStateSource() async throws {
    let manager = GameServerStateManager(maximumRetainedStates: 3, maximumPendingUpdates: 8)
    try await manager.start()
    let publisher = try await manager.publisher()
    for index in 0..<3 {
        let record = try GameServerStateRecord(namespace: "session", key: "player-\(index)", revision: UInt64(index + 1), payload: Data("{\"position\":\(index)}".utf8))
        #expect(publisher.publish(record) != .unavailable)
    }
    var page = await manager.snapshot(offset: 0, limit: 1)
    for _ in 0..<30 where page.total < 3 {
        try await Task.sleep(for: .milliseconds(5))
        page = await manager.snapshot(offset: 0, limit: 1)
    }
    #expect(page.total == 3 && page.records.count == 1)
    let stale = try GameServerStateRecord(namespace: "session", key: "player-0", revision: 0, payload: Data("stale".utf8))
    #expect(publisher.publish(stale) == .enqueued)
    try await Task.sleep(for: .milliseconds(10))
    let retained = await manager.snapshot().first { $0.key == "player-0" }
    #expect(retained?.revision == 1)
    let source = PearfyGameServerDevKit.source(manager: manager)
    let dashboard = try await source.snapshot(for: DevKitQuery(window: .fifteenMinutes, stateOffset: 1, stateLimit: 1))
    #expect(dashboard.gameStateCount == 3)
    #expect(dashboard.gameStates.count == 1)
    #expect(dashboard.availableSources.contains("gameserver-state"))
    await manager.stop()
}

@Test func gameStateManagerFansOutToRecoveryDatabaseAndDashboard() async throws {
    let store = MemoryGameStateRecoveryStore()
    let sessionID = UUID()
    let recovery = try RedisGameServerStateMiddleware(
        store: store,
        sessionID: sessionID,
        epoch: 1,
        checkpointEvery: 1,
        maximumRetainedStates: 8,
        maximumEventsPerSession: 16
    )
    let database = CapturedGameStateSink()
    let databaseMiddleware = GameServerStateClosureMiddleware { record in
        await database.persist(record)
    }
    let manager = GameServerStateManager(maximumRetainedStates: 8, maximumPendingUpdates: 8)

    try await manager.start(restoringFrom: recovery, middlewares: [databaseMiddleware])
    let publisher = try await manager.publisher()
    let record = try GameServerStateRecord(
        namespace: "match",
        key: "current",
        revision: 12,
        payload: Data("{\"phase\":\"active\"}".utf8)
    )
    #expect(publisher.publish(record) == .enqueued)
    await manager.stop()

    let recovered = try await recovery.restore()
    #expect(recovered == [record])
    #expect(await database.records == [record])
    let dashboard = try await PearfyGameServerDevKit.source(manager: manager)
        .snapshot(for: DevKitQuery(window: .fifteenMinutes, stateOffset: 0, stateLimit: 100))
    #expect(dashboard.gameStateCount == 1)
    #expect(dashboard.gameStates.first?.id == record.id)
}

@Test func gameStateMailboxBoundsPendingPayloadBytes() async throws {
    let mailbox = GameServerStateMailbox(maximumItems: 10, maximumBytes: 1_048_576)
    let payload = Data(repeating: 7, count: 600_000)
    let first = try GameServerStateRecord(namespace: "zone", key: "first", revision: 1, payload: payload)
    let replaced = try GameServerStateRecord(namespace: "zone", key: "replaced", revision: 1, payload: payload)
    let latest = try GameServerStateRecord(namespace: "zone", key: "latest", revision: 1, payload: payload)

    #expect(mailbox.enqueue(first) == .enqueued)
    #expect(mailbox.enqueue(replaced) == .replacedOlder)
    #expect(mailbox.enqueue(latest) == .replacedOlder)
    #expect(await mailbox.next() == latest)
    mailbox.finish()
    #expect(await mailbox.next() == nil)
}

@Test func rejectedStateRestoreKeepsThePreviousSnapshotIntact() async throws {
    let manager = GameServerStateManager(maximumRetainedStates: 1, maximumPendingUpdates: 2)
    let original = try GameServerStateRecord(namespace: "world", key: "checkpoint", revision: 7, payload: Data("stable".utf8))
    let extra = try GameServerStateRecord(namespace: "world", key: "extra", revision: 1, payload: Data("overflow".utf8))
    try await manager.restore([original])

    do {
        try await manager.restore([original, extra])
        Issue.record("restore beyond the configured state count must fail")
    } catch {
        #expect(error as? GameServerStateManagerError == .invalidConfiguration)
    }

    #expect(await manager.snapshot() == [original])
    #expect(await manager.metrics().retainedStateBytes == original.payload.count)

    let byteBoundedManager = GameServerStateManager(
        maximumRetainedStates: 2,
        maximumPendingUpdates: 2,
        maximumRetainedStateBytes: 1_048_576
    )
    let largeOriginal = try GameServerStateRecord(
        namespace: "world", key: "large", revision: 3, payload: Data(repeating: 1, count: 900_000)
    )
    let oversizedAdditional = try GameServerStateRecord(
        namespace: "world", key: "additional", revision: 1, payload: Data(repeating: 2, count: 200_000)
    )
    try await byteBoundedManager.restore([largeOriginal])
    do {
        try await byteBoundedManager.restore([largeOriginal, oversizedAdditional])
        Issue.record("restore beyond the configured byte budget must fail")
    } catch {
        #expect(error as? GameServerStateManagerError == .invalidConfiguration)
    }
    #expect(await byteBoundedManager.snapshot() == [largeOriginal])
    #expect(await byteBoundedManager.metrics().retainedStateBytes == largeOriginal.payload.count)
}

@Test func gameStateRestoreDeduplicatesByHighestRevisionWithoutDoubleCountingBytes() async throws {
    let manager = GameServerStateManager(maximumRetainedStates: 3, maximumPendingUpdates: 2, maximumRetainedStateBytes: 1_048_576)
    let older = try GameServerStateRecord(namespace: "world", key: "npc", revision: 1, updatedAt: Date(timeIntervalSince1970: 1), payload: Data(repeating: 1, count: 900_000))
    let newer = try GameServerStateRecord(namespace: "world", key: "npc", revision: 2, updatedAt: Date(timeIntervalSince1970: 2), payload: Data(repeating: 2, count: 900_000))
    try await manager.restore([older, newer])
    let metrics = await manager.metrics()
    #expect(metrics.retainedStateCount == 1)
    #expect(metrics.retainedStateBytes == 900_000)
    #expect(await manager.snapshot().first?.revision == 2)
}

@Test func redisRecoveryMiddlewareRestoresCheckpointAndRejectsStaleEpoch() async throws {
    let store = MemoryGameStateRecoveryStore()
    let sessionID = UUID()
    let middleware = try RedisGameServerStateMiddleware(store: store, sessionID: sessionID, epoch: 3, checkpointEvery: 2, maximumRetainedStates: 8, maximumEventsPerSession: 16)
    let first = try GameServerStateRecord(namespace: "world", key: "npc-1", revision: 1, payload: Data("{\"x\":1}".utf8))
    let second = try GameServerStateRecord(namespace: "world", key: "npc-2", revision: 2, payload: Data("{\"x\":2}".utf8))
    try await middleware.persist(first)
    try await middleware.persist(second)
    try await middleware.flush()
    let restoredMiddleware = try RedisGameServerStateMiddleware(store: store, sessionID: sessionID, epoch: 3, checkpointEvery: 2, maximumRetainedStates: 8, maximumEventsPerSession: 16)
    let restored = try await restoredMiddleware.restore()
    #expect(restored.sorted { $0.id < $1.id } == [first, second].sorted { $0.id < $1.id })
    let startupRecovery = try RedisGameServerStateMiddleware(store: store, sessionID: sessionID, epoch: 3, checkpointEvery: 2, maximumRetainedStates: 8, maximumEventsPerSession: 16)
    let manager = GameServerStateManager(maximumRetainedStates: 8, maximumPendingUpdates: 8)
    try await manager.start(restoringFrom: startupRecovery)
    #expect(await manager.snapshot().sorted { $0.id < $1.id } == [first, second].sorted { $0.id < $1.id })
    await manager.stop()
    let staleMiddleware = try RedisGameServerStateMiddleware(store: store, sessionID: sessionID, epoch: 2, checkpointEvery: 2, maximumRetainedStates: 8, maximumEventsPerSession: 16)
    do { _ = try await staleMiddleware.restore(); Issue.record("stale recovery epoch must be rejected") }
    catch { #expect(error as? RedisGameStateRecoveryError == .staleEpoch) }
}

@Test func redisRecoveryMiddlewareCheckpointsOnElapsedIntervalAfterStateUpdate() async throws {
    let store = MemoryGameStateRecoveryStore()
    let sessionID = UUID()
    let middleware = try RedisGameServerStateMiddleware(
        store: store,
        sessionID: sessionID,
        epoch: 1,
        checkpointEvery: 100,
        checkpointIntervalMilliseconds: 100
    )
    let first = try GameServerStateRecord(namespace: "world", key: "npc-1", revision: 1, payload: Data([1]))
    let second = try GameServerStateRecord(namespace: "world", key: "npc-2", revision: 1, payload: Data([2]))

    try await middleware.persist(first)
    #expect(await store.savedCheckpointCount == 1) // initial empty checkpoint
    try await Task.sleep(for: .milliseconds(120))
    try await middleware.persist(second)

    #expect(await store.savedCheckpointCount == 2)
    let recovered = try #require(try await store.load(sessionID: sessionID))
    #expect(recovered.checkpoint.revision == 2)
    #expect(recovered.events.isEmpty)
    let restored = try RedisGameServerStateMiddleware(store: store, sessionID: sessionID, epoch: 1)
    #expect(try await restored.restore().sorted { $0.id < $1.id } == [first, second].sorted { $0.id < $1.id })
}

@Test func redisRecoveryMiddlewareElapsedCheckpointRoundTripsWithRedis() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_PORT"] ?? "6379") ?? 6379
    let configuration = try RedisGameStateRecoveryConfiguration(
        host: host,
        port: port,
        keyPrefix: "pearfy-game-timed-checkpoint-\(UUID().uuidString.lowercased())"
    )
    let store = RedisGameStateRecoveryStore(configuration: configuration)
    try await store.start()
    do {
        let sessionID = UUID()
        let lease = try await store.acquireLease(sessionID: sessionID)
        let middleware = try RedisGameServerStateMiddleware(
            store: store,
            sessionID: sessionID,
            epoch: lease.epoch,
            checkpointEvery: 100,
            checkpointIntervalMilliseconds: 100
        )
        let first = try GameServerStateRecord(namespace: "world", key: "npc-1", revision: 1, payload: Data([1]))
        let second = try GameServerStateRecord(namespace: "world", key: "npc-2", revision: 1, payload: Data([2]))
        try await middleware.persist(first)
        try await Task.sleep(for: .milliseconds(120))
        try await middleware.persist(second)
        let recovered = try #require(try await store.load(sessionID: sessionID))
        #expect(recovered.epoch == lease.epoch)
        #expect(recovered.checkpoint.revision == 2)
        #expect(recovered.events.isEmpty)
        #expect(try await middleware.restore().sorted { $0.id < $1.id } == [first, second].sorted { $0.id < $1.id })
        try await store.stop()
    } catch {
        try? await store.stop()
        throw error
    }
}

@Test func gameStateRecordDecodingEnforcesIdentifierBounds() throws {
    let valid = try GameServerStateRecord(namespace: "world", key: "npc-1", revision: 1, payload: Data([1]))
    let encoded = try JSONEncoder().encode(valid)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["key"] = "../private"
    let tampered = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(GameServerStateRecord.self, from: tampered) }
}

@Test func redisRecoveryCheckpointSchedulerRunsOffTickAndStopsCleanly() async throws {
    let store = MemoryGameStateRecoveryStore()
    let sessionID = UUID()
    let captureCount = SchedulerCaptureCounter()
    let scheduler = try GameStateRecoveryCheckpointScheduler(
        store: store,
        sessionID: sessionID,
        epoch: 1,
        intervalMilliseconds: 100,
        maximumCheckpointBytes: 128,
        capture: {
            await captureCount.increment()
            return GameStateCheckpoint(revision: 0, state: Data([1, 2, 3]), events: [])
        }
    )
    try await scheduler.start()
    try await Task.sleep(for: .milliseconds(260))
    await scheduler.stop()

    let metrics = await scheduler.metrics()
    #expect(await captureCount.value >= 2)
    #expect(metrics.successfulCheckpoints >= 2)
    #expect(metrics.failedCheckpoints == 0)
    #expect(metrics.lastSuccessfulCheckpointAt != nil)
    #expect(!metrics.isRunning)
}

@Test func redisRecoveryCheckpointSchedulerRejectsOversizedSnapshots() async throws {
    let store = MemoryGameStateRecoveryStore()
    let scheduler = try GameStateRecoveryCheckpointScheduler(
        store: store,
        sessionID: UUID(),
        epoch: 1,
        intervalMilliseconds: 10_000,
        maximumCheckpointBytes: 2,
        capture: { GameStateCheckpoint(revision: 0, state: Data([1, 2, 3]), events: []) }
    )
    do {
        try await scheduler.checkpointNow()
        Issue.record("oversized checkpoints must be rejected before reaching the store")
    } catch {
        #expect(error as? GameStateRecoveryCheckpointSchedulerError == .checkpointTooLarge(maximumBytes: 2))
    }
    #expect(await scheduler.metrics().failedCheckpoints == 1)
    #expect(await store.savedCheckpointCount == 0)
}

@Test func redisRecoveryCheckpointSchedulerRejectsConcurrentCaptures() async throws {
    let store = MemoryGameStateRecoveryStore()
    let scheduler = try GameStateRecoveryCheckpointScheduler(
        store: store,
        sessionID: UUID(),
        epoch: 1,
        intervalMilliseconds: 10_000,
        capture: {
            try await Task.sleep(for: .milliseconds(80))
            return GameStateCheckpoint(revision: 0, state: Data([1]), events: [])
        }
    )
    async let first: Void = scheduler.checkpointNow()
    try await Task.sleep(for: .milliseconds(10))
    do {
        try await scheduler.checkpointNow()
        Issue.record("a concurrent checkpoint capture must be rejected")
    } catch {
        #expect(error as? GameStateRecoveryCheckpointSchedulerError == .checkpointInProgress)
    }
    try await first
    #expect(await scheduler.metrics().successfulCheckpoints == 1)
    #expect(await scheduler.metrics().failedCheckpoints == 0)
}

@Test func redisRecoveryConfigurationRequiresTLSForRemoteHosts() throws {
    #expect(throws: RedisGameStateRecoveryError.invalidConfiguration) {
        try RedisGameStateRecoveryConfiguration(host: "redis.internal", password: "secret")
    }
    let remote = try RedisGameStateRecoveryConfiguration(host: "redis.internal", password: "secret", tlsEnabled: true, serverName: "redis.internal")
    #expect(remote.tlsEnabled)
    #expect(remote.serverName == "redis.internal")
    #expect(throws: RedisGameStateRecoveryError.invalidConfiguration) {
        try RedisGameStateRecoveryConfiguration(host: "redis.internal", password: "secret", tlsEnabled: true, serverName: "redis.internal\r\n")
    }
}

@Test func redisRecoveryMetadataRejectsPartialStateButAllowsFreshLeasedSession() throws {
    let fresh = try decodeRedisGameRecoveryMetadata(
        snapshotJSON: nil, epochText: "1", sequenceText: nil, streamLength: 0,
        maximumRecordBytes: 1_024, maximumRecoveryBytes: 2_048
    )
    #expect(fresh == nil)

    #expect(throws: RedisGameStateRecoveryError.self) {
        try decodeRedisGameRecoveryMetadata(
            snapshotJSON: nil, epochText: "1", sequenceText: "3", streamLength: 0,
            maximumRecordBytes: 1_024, maximumRecoveryBytes: 2_048
        )
    }
    #expect(throws: RedisGameStateRecoveryError.self) {
        try decodeRedisGameRecoveryMetadata(
            snapshotJSON: nil, epochText: "1", sequenceText: nil, streamLength: 1,
            maximumRecordBytes: 1_024, maximumRecoveryBytes: 2_048
        )
    }
    #expect(throws: RedisGameStateRecoveryError.self) {
        try decodeRedisGameRecoveryMetadata(
            snapshotJSON: "not-base64", epochText: "1", sequenceText: "0", streamLength: 0,
            maximumRecordBytes: 1_024, maximumRecoveryBytes: 2_048
        )
    }
    #expect(throws: RedisGameStateRecoveryError.self) {
        try decodeRedisGameRecoveryMetadata(
            snapshotJSON: Data(repeating: 1, count: 1_025).base64EncodedString(),
            epochText: "1", sequenceText: "0", streamLength: 0,
            maximumRecordBytes: 1_024, maximumRecoveryBytes: 2_048
        )
    }
}

@Test func redisSnapshotChunksAreBoundedAndChecksumVerified() throws {
    let checkpoint = Data(repeating: 0x6d, count: 600_000)
    let chunked = RedisGameSnapshotManifest.make(for: checkpoint)
    #expect(chunked.manifest.chunkCount > 1)
    #expect(chunked.chunks.allSatisfy { $0.utf8.count <= RedisGameSnapshotManifest.chunkByteLimit })
    let parsed = try #require(try RedisGameSnapshotManifest.parse(
        chunked.manifest.encodedValue, maximumRecordBytes: 1_000_000, maximumRecoveryBytes: 1_000_000
    ))
    #expect(try parsed.decode(chunks: chunked.chunks, maximumRecordBytes: 1_000_000, maximumRecoveryBytes: 1_000_000) == checkpoint)

    var corruptedChunks = chunked.chunks
    corruptedChunks[0].replaceSubrange(corruptedChunks[0].startIndex...corruptedChunks[0].startIndex, with: "A")
    #expect(throws: RedisGameStateRecoveryError.invalidResponse) {
        try parsed.decode(chunks: corruptedChunks, maximumRecordBytes: 1_000_000, maximumRecoveryBytes: 1_000_000)
    }
    #expect(throws: RedisGameStateRecoveryError.invalidResponse) {
        try RedisGameSnapshotManifest.parse(
            "\(RedisGameSnapshotManifest.marker)bad:1:4:3", maximumRecordBytes: 1_000, maximumRecoveryBytes: 1_000
        )
    }
    #expect(throws: RedisGameStateRecoveryError.recordTooLarge(maximumBytes: 500_000)) {
        try parsed.decode(chunks: chunked.chunks, maximumRecordBytes: 500_000, maximumRecoveryBytes: 1_000_000)
    }
}

@Test func redisRecoveryIntegrationRoundTripsChunkedCheckpoint() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_PORT"] ?? "6379") ?? 6379
    let prefix = "pearfy-game-chunks-test-\(UUID().uuidString.lowercased())"
    let configuration = try RedisGameStateRecoveryConfiguration(
        host: host, port: port, keyPrefix: prefix, maximumRecordBytes: 2_097_152, maximumRecoveryBytes: 4_194_304
    )
    let store = RedisGameStateRecoveryStore(configuration: configuration)
    try await store.start()
    defer { Task { try? await store.stop() } }

    let sessionID = UUID()
    let lease = try await store.acquireLease(sessionID: sessionID)
    let checkpoint = GameStateCheckpoint(revision: 0, state: Data(repeating: 0x41, count: 700_000), events: [])
    try await store.save(sessionID: sessionID, epoch: lease.epoch, checkpoint: checkpoint)
    try await store.save(sessionID: sessionID, epoch: lease.epoch, checkpoint: checkpoint)
    let loaded = try #require(try await store.load(sessionID: sessionID))
    #expect(loaded.checkpoint == checkpoint)
    #expect(loaded.latestSequence == 0)

    try await store.append(
        sessionID: sessionID, epoch: lease.epoch,
        event: GameStateEvent(sequence: 1, commandID: UUID(), playerID: UUID(), payload: Data([1]), state: Data())
    )
    // Replacing a checkpoint must remove its obsolete chunks after the new watermark commits.
    let replacement = GameStateCheckpoint(revision: 1, state: Data(repeating: 0x42, count: 700_000), events: [])
    try await store.save(sessionID: sessionID, epoch: lease.epoch, checkpoint: replacement)
    #expect(try await store.load(sessionID: sessionID)?.checkpoint == replacement)

    #expect(try await store.releaseLease(lease))
    let nextLease = try await store.acquireLease(sessionID: sessionID)
    #expect(nextLease.epoch == lease.epoch + 1)
    do {
        try await store.save(sessionID: sessionID, epoch: lease.epoch, checkpoint: replacement)
        Issue.record("a stale writer cannot publish a checkpoint after takeover")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .staleEpoch)
    }
    let fenced = try #require(try await store.load(sessionID: sessionID))
    #expect(fenced.epoch == nextLease.epoch)
    #expect(fenced.checkpoint == replacement)
}

@Test func redisRecoveryIntegrationReplaysCheckpointAndStopsCleanly() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_PORT"] ?? "6379") ?? 6379
    let password = ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_PASSWORD"]
    let prefix = "pearfy-game-test-\(UUID().uuidString.lowercased())"
    let configuration = try RedisGameStateRecoveryConfiguration(host: host, port: port, password: password, keyPrefix: prefix)
    let store = RedisGameStateRecoveryStore(configuration: configuration)
    try await store.start()
    defer { Task { try? await store.stop() } }

    let sessionID = UUID()
    let lease = try await store.acquireLease(sessionID: sessionID)
    if case .some = try await store.load(sessionID: sessionID) {
        Issue.record("a newly leased session without a journal should restore as empty")
    }
    #expect(lease.epoch == 1)
    let writer = try RedisGameServerStateMiddleware(store: store, sessionID: sessionID, epoch: lease.epoch, checkpointEvery: 2)
    let first = try GameServerStateRecord(namespace: "world", key: "npc-a", revision: 1, payload: Data("{\"x\":1}".utf8))
    let second = try GameServerStateRecord(namespace: "world", key: "npc-b", revision: 2, payload: Data("{\"x\":2}".utf8))
    try await writer.persist(first)
    try await writer.persist(second)
    try await writer.flush()
    do {
        try await store.save(sessionID: sessionID, epoch: lease.epoch, checkpoint: GameStateCheckpoint(revision: 1, state: Data("stale-checkpoint".utf8), events: []))
        Issue.record("an older checkpoint must not replace the latest Redis snapshot")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .staleCheckpoint)
    }

    let restored = try RedisGameServerStateMiddleware(store: store, sessionID: sessionID, epoch: lease.epoch)
    #expect(try await restored.restore().sorted { $0.id < $1.id } == [first, second].sorted { $0.id < $1.id })
    async let firstStop = try store.stop()
    async let secondStop = try store.stop()
    try await firstStop
    try await secondStop
}

@Test func redisRecoveryMiddlewareRejectsStaleAndConflictingProjectionRevisions() async throws {
    let store = MemoryGameStateRecoveryStore()
    let sessionID = UUID()
    let writer = try RedisGameServerStateMiddleware(
        store: store, sessionID: sessionID, epoch: 1, checkpointEvery: 100,
        checkpointIntervalMilliseconds: nil
    )
    let latest = try GameServerStateRecord(namespace: "world", key: "npc", revision: 4, payload: Data("new".utf8))
    try await writer.persist(latest)

    let stale = try GameServerStateRecord(namespace: "world", key: "npc", revision: 3, payload: Data("old".utf8))
    do {
        try await writer.persist(stale)
        Issue.record("older projection revisions must not enter the recovery journal")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .staleProjection)
    }

    let conflict = try GameServerStateRecord(namespace: "world", key: "npc", revision: 4, payload: Data("conflict".utf8))
    do {
        try await writer.persist(conflict)
        Issue.record("the same revision cannot describe two different states")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .projectionRevisionConflict)
    }

    try await writer.persist(latest)
    let next = try GameServerStateRecord(namespace: "world", key: "npc", revision: 5, payload: Data("newer".utf8))
    try await writer.persist(next)
    #expect(await store.eventCount == 2)

    let restored = try RedisGameServerStateMiddleware(store: store, sessionID: sessionID, epoch: 1)
    #expect(try await restored.restore() == [next])
}

@Test func redisDurableCommandSessionCommitsAfterAppendAndRecoversIdempotently() async throws {
    let store = DurableCommandMemoryStore()
    let sessionID = UUID()
    let lease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 1, durationMilliseconds: 15_000)
    let initial = Data("0".utf8)
    let reduce: RedisDurableGameCommandSession.Reducer = { current, _, command in
        let value = Int(String(decoding: current, as: UTF8.self)) ?? 0
        let delta = Int(String(decoding: command, as: UTF8.self)) ?? 0
        return Data(String(value + delta).utf8)
    }
    let session = try await RedisDurableGameCommandSession.open(
        sessionID: sessionID, lease: lease, store: store, initialState: initial, reducer: reduce
    )
    let firstCommandID = UUID()
    let playerID = UUID()
    await store.failNextAppendAfterCommit()
    do {
        _ = try await session.commit(commandID: firstCommandID, playerID: playerID, command: Data("4".utf8))
        Issue.record("an ambiguous append failure must not be reported as a committed command")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .journalUnavailable)
    }
    #expect(await session.snapshot().revision == 0)
    #expect(await session.snapshot().state == initial)

    let committed = try await session.commit(commandID: firstCommandID, playerID: playerID, command: Data("4".utf8))
    #expect(committed.sequence == 1)
    #expect(!committed.isDuplicate)
    #expect(committed.state == Data("4".utf8))
    let duplicate = try await session.commit(commandID: firstCommandID, playerID: playerID, command: Data("4".utf8))
    #expect(duplicate.sequence == 1)
    #expect(duplicate.isDuplicate)
    do {
        _ = try await session.commit(commandID: firstCommandID, playerID: playerID, command: Data("5".utf8))
        Issue.record("command ID reuse with a different payload must be rejected")
    } catch {
        #expect(error as? GameServerError == .commandIDConflict)
    }

    try await session.checkpoint()
    let second = try await session.commit(commandID: UUID(), playerID: playerID, command: Data("3".utf8), expectedRevision: 1)
    #expect(second.sequence == 2)
    #expect(second.state == Data("7".utf8))

    let takeover = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 2, durationMilliseconds: 15_000)
    await store.takeover(epoch: takeover.epoch)
    let restored = try await RedisDurableGameCommandSession.open(
        sessionID: sessionID, lease: takeover, store: store, reducer: reduce
    )
    #expect(await restored.snapshot().revision == 2)
    #expect(await restored.snapshot().state == Data("7".utf8))
    #expect(await restored.processedCommandCount == 2)
    let replayedDuplicate = try await restored.commit(commandID: firstCommandID, playerID: playerID, command: Data("4".utf8))
    #expect(replayedDuplicate.isDuplicate)
    #expect(replayedDuplicate.sequence == 1)
}

@Test func redisDurableCommandSessionDoesNotAcceptConcurrentCommitDuringJournalWrite() async throws {
    let store = DurableCommandMemoryStore()
    let sessionID = UUID()
    let lease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 1, durationMilliseconds: 15_000)
    let session = try await RedisDurableGameCommandSession.open(
        sessionID: sessionID,
        lease: lease,
        store: store,
        initialState: Data("0".utf8),
        reducer: { current, _, command in Data((Int(String(decoding: current, as: UTF8.self))! + Int(String(decoding: command, as: UTF8.self))!).description.utf8) }
    )
    await store.pauseNextAppend()
    let first = Task { try await session.commit(commandID: UUID(), playerID: UUID(), command: Data("1".utf8)) }
    await store.waitForPausedAppend()
    #expect(await session.snapshot().revision == 0)
    do {
        _ = try await session.commit(commandID: UUID(), playerID: UUID(), command: Data("2".utf8))
        Issue.record("a session must not admit a second command while its sequence is unresolved")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .commandCommitInProgress)
    }
    do {
        try await session.checkpoint()
        Issue.record("a checkpoint must not overtake an unresolved journal append")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .commandCommitInProgress)
    }
    await store.resumeAppend()
    #expect(try await first.value.sequence == 1)
    #expect(await session.snapshot().state == Data("1".utf8))
}

@Test func redisDurableAsyncReducerHoldsCommitGateAcrossActorSuspension() async throws {
    let store = DurableCommandMemoryStore()
    let gate = AsyncGameReducerGate()
    let sessionID = UUID()
    let session = try await RedisDurableGameCommandSession.openAsync(
        sessionID: sessionID,
        lease: GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 1, durationMilliseconds: 15_000),
        store: store,
        initialState: Data("0".utf8),
        reducer: { current, _, command in
            await gate.pauseUntilReleased()
            return Data("\(Int(String(decoding: current, as: UTF8.self))! + Int(String(decoding: command, as: UTF8.self))!)".utf8)
        }
    )

    let first = Task { try await session.commit(commandID: UUID(), playerID: UUID(), command: Data("1".utf8)) }
    await gate.waitUntilPaused()
    #expect(await session.snapshot().revision == 0)
    do {
        _ = try await session.commit(commandID: UUID(), playerID: UUID(), command: Data("2".utf8))
        Issue.record("a second command must not enter while an async reducer is suspended")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .commandCommitInProgress)
    }
    do {
        try await session.checkpoint()
        Issue.record("checkpoint must not overtake an async reducer")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .commandCommitInProgress)
    }
    await gate.release()
    #expect(try await first.value.sequence == 1)
    #expect(await session.snapshot().state == Data("1".utf8))
}

@Test func redisDurableCommandSessionRecoversJournalSuffixFromRedis() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_PORT"] ?? "6379") ?? 6379
    let configuration = try RedisGameStateRecoveryConfiguration(
        host: host,
        port: port,
        keyPrefix: "pearfy-durable-command-\(UUID().uuidString.lowercased())"
    )
    let store = RedisGameStateRecoveryStore(configuration: configuration)
    try await store.start()
    do {
        let sessionID = UUID()
        let firstLease = try await store.acquireLease(sessionID: sessionID)
        let reducer: RedisDurableGameCommandSession.Reducer = { current, _, command in
            let currentValue = Int(String(decoding: current, as: UTF8.self)) ?? 0
            let delta = Int(String(decoding: command, as: UTF8.self)) ?? 0
            return Data(String(currentValue + delta).utf8)
        }
        let session = try await RedisDurableGameCommandSession.open(
            sessionID: sessionID,
            lease: firstLease,
            store: store,
            initialState: Data("0".utf8),
            reducer: reducer
        )
        let playerID = UUID()
        let firstID = UUID()
        let first = try await session.commit(commandID: firstID, playerID: playerID, command: Data("6".utf8))
        try await session.checkpoint()
        let second = try await session.commit(commandID: UUID(), playerID: playerID, command: Data("2".utf8))
        #expect(first.sequence == 1)
        #expect(second.sequence == 2)
        #expect(second.state == Data("8".utf8))
        #expect(try await store.releaseLease(firstLease))

        let nextLease = try await store.acquireLease(sessionID: sessionID)
        #expect(nextLease.epoch == firstLease.epoch + 1)
        let restored = try await RedisDurableGameCommandSession.open(
            sessionID: sessionID, lease: nextLease, store: store, reducer: reducer
        )
        #expect(await restored.snapshot().revision == 2)
        #expect(await restored.snapshot().state == Data("8".utf8))
        let duplicate = try await restored.commit(commandID: firstID, playerID: playerID, command: Data("6".utf8))
        #expect(duplicate.isDuplicate)
        #expect(duplicate.sequence == 1)
        try await store.stop()
    } catch {
        try? await store.stop()
        throw error
    }
}

@Test func redisDurableCoopSessionCommitsAndReplaysMissionCommands() async throws {
    let store = DurableCommandMemoryStore()
    let sessionID = UUID()
    let playerID = UUID()
    let firstLease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 1, durationMilliseconds: 15_000)
    let game = try GameCoopSession(
        sessionID: sessionID,
        objectives: ["investigate"],
        maximumStateBytes: 1_048_576,
        deterministicSeed: 0xA11CE
    )
    let configuration = try RedisDurableGameCommandConfiguration(
        maximumStateBytes: 16_777_216,
        maximumCommandBytes: 65_536,
        maximumProcessedCommands: 128,
        maximumReplayEvents: 1_000,
        maximumCheckpointBytes: 16_777_216
    )
    let durable = try await RedisDurableGameCoopSession.open(
        initialSession: game,
        lease: firstLease,
        store: store,
        configuration: configuration
    )

    let joinID = UUID()
    let joined = try await durable.commit(
        commandID: joinID,
        playerID: playerID,
        command: .join(playerID: playerID)
    )
    #expect(joined.sequence == 1)
    _ = try await durable.commit(commandID: UUID(), playerID: playerID, command: .start)
    let decisionID = UUID()
    let decision = try await durable.deterministicDecision(commandID: decisionID, playerID: playerID)
    #expect(decision.receipt.sequence == 3)
    try await durable.checkpoint()
    _ = try await durable.commit(
        commandID: UUID(),
        playerID: playerID,
        command: .scheduleNPCAction(GameCoopScheduledNPCAction(npcID: "warden", dueTick: 4, payload: Data("approach".utf8)))
    )
    let objectiveCommandID = UUID()
    let objective = RedisDurableGameCoopCommand.completeObjective(
        objectiveID: "investigate",
        playerID: playerID,
        publicState: Data("clue-found".utf8),
        privatePlayerState: Data("private-clue".utf8)
    )
    let completion = try await durable.commit(commandID: objectiveCommandID, playerID: playerID, command: objective)
    #expect(completion.sequence == 5)
    let visible = try await durable.snapshot(for: playerID)
    #expect(visible.completedObjectives == ["investigate"])
    #expect(visible.privatePlayerState[playerID] == Data("private-clue".utf8))

    let duplicate = try await durable.commit(commandID: objectiveCommandID, playerID: playerID, command: objective)
    #expect(duplicate.isDuplicate)
    #expect(duplicate.sequence == 5)
    let retriedDecision = try await durable.deterministicDecision(commandID: decisionID, playerID: playerID)
    #expect(retriedDecision.receipt.isDuplicate)
    #expect(retriedDecision.receipt.sequence == 3)
    #expect(retriedDecision.value == decision.value)

    let stageCommandID = UUID()
    let staged = try await durable.stageNPCActions(
        commandID: stageCommandID,
        playerID: playerID,
        tick: 4,
        maximumActions: 1,
        expectedRevision: 5
    )
    #expect(staged.receipt.sequence == 6)
    #expect(staged.batch.actions.map(\.npcID) == ["warden"])
    let retriedStage = try await durable.stageNPCActions(
        commandID: stageCommandID,
        playerID: playerID,
        tick: 4,
        maximumActions: 1
    )
    #expect(retriedStage.receipt.isDuplicate)
    #expect(retriedStage.batch == staged.batch)

    let nextLease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 2, durationMilliseconds: 15_000)
    await store.takeover(epoch: nextLease.epoch)
    let restored = try await RedisDurableGameCoopSession.open(
        sessionID: sessionID,
        lease: nextLease,
        store: store,
        configuration: configuration
    )
    #expect((await restored.journalSnapshot()).revision == 6)
    let recovered = try await restored.snapshot(for: playerID)
    #expect(recovered.completedObjectives == ["investigate"])
    #expect(recovered.privatePlayerState[playerID] == Data("private-clue".utf8))
    let recoveredDecision = try await restored.deterministicDecision(commandID: decisionID, playerID: playerID)
    #expect(recoveredDecision.receipt.isDuplicate)
    #expect(recoveredDecision.receipt.sequence == 3)
    #expect(recoveredDecision.value == decision.value)
    let recoveredSession = try GameCoopSession(restoringCheckpoint: (await restored.journalSnapshot()).state)
    #expect(await recoveredSession.queuedNPCActionCount == 0)
    #expect(await recoveredSession.pendingNPCDispatchCount == 1)
    #expect(try await restored.pendingNPCActionBatch().actions == staged.batch.actions)
    #expect(try await restored.commit(commandID: joinID, playerID: playerID, command: .join(playerID: playerID)).isDuplicate)
    let acknowledgementID = UUID()
    let acknowledged = try await restored.acknowledgeNPCActions(
        commandID: acknowledgementID,
        playerID: playerID,
        actionIDs: staged.batch.actions.map(\.id)
    )
    #expect(acknowledged.sequence == 7)
    #expect(try await restored.pendingNPCActionBatch().actions.isEmpty)
    #expect(try await restored.acknowledgeNPCActions(
        commandID: acknowledgementID,
        playerID: playerID,
        actionIDs: staged.batch.actions.map(\.id)
    ).isDuplicate)
}

@Test func redisDurableCoopSessionRejectsRandomDecisionWithoutSeed() async throws {
    let store = DurableCommandMemoryStore()
    let sessionID = UUID()
    let playerID = UUID()
    let lease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 1, durationMilliseconds: 15_000)
    let game = try GameCoopSession(sessionID: sessionID, objectives: [])
    let durable = try await RedisDurableGameCoopSession.open(initialSession: game, lease: lease, store: store)
    _ = try await durable.commit(commandID: UUID(), playerID: playerID, command: .join(playerID: playerID))
    _ = try await durable.commit(commandID: UUID(), playerID: playerID, command: .start)
    do {
        _ = try await durable.deterministicDecision(commandID: UUID(), playerID: playerID)
        Issue.record("expected an unseeded random decision to be rejected")
    } catch let error as GameServerError {
        #expect(error == .invalidCoopTransition)
    }
    #expect((await durable.journalSnapshot()).revision == 2)
}

@Test func redisDurableCoopSessionRejectsRandomDecisionForNonMember() async throws {
    let store = DurableCommandMemoryStore()
    let sessionID = UUID()
    let memberID = UUID()
    let nonMemberID = UUID()
    let lease = GameStateSessionLease(sessionID: sessionID, ownerID: UUID(), epoch: 1, durationMilliseconds: 15_000)
    let game = try GameCoopSession(sessionID: sessionID, objectives: [], deterministicSeed: 42)
    let durable = try await RedisDurableGameCoopSession.open(initialSession: game, lease: lease, store: store)
    _ = try await durable.commit(commandID: UUID(), playerID: memberID, command: .join(playerID: memberID))
    _ = try await durable.commit(commandID: UUID(), playerID: memberID, command: .start)
    do {
        _ = try await durable.deterministicDecision(commandID: UUID(), playerID: nonMemberID)
        Issue.record("expected a non-member random decision to be rejected")
    } catch let error as GameServerError {
        #expect(error == .invalidCoopTransition)
    }
    #expect((await durable.journalSnapshot()).revision == 2)
}

@Test func redisDurableCoopSessionRecoversJournalSuffixFromRedis() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_PORT"] ?? "6379") ?? 6379
    let configuration = try RedisGameStateRecoveryConfiguration(
        host: host,
        port: port,
        keyPrefix: "pearfy-durable-coop-\(UUID().uuidString.lowercased())"
    )
    let store = RedisGameStateRecoveryStore(configuration: configuration)
    try await store.start()
    do {
        let sessionID = UUID()
        let firstLease = try await store.acquireLease(sessionID: sessionID)
        let playerID = UUID()
        let game = try GameCoopSession(sessionID: sessionID, objectives: ["restore-power"])
        let durableConfiguration = try RedisDurableGameCommandConfiguration(
            maximumStateBytes: 16_777_216,
            maximumCommandBytes: 65_536,
            maximumProcessedCommands: 128,
            maximumReplayEvents: 1_000,
            maximumCheckpointBytes: 16_777_216
        )
        let mission = try await RedisDurableGameCoopSession.open(
            initialSession: game,
            lease: firstLease,
            store: store,
            configuration: durableConfiguration
        )
        let joinID = UUID()
        _ = try await mission.commit(commandID: joinID, playerID: playerID, command: .join(playerID: playerID))
        _ = try await mission.commit(commandID: UUID(), playerID: playerID, command: .start)
        let completionID = UUID()
        let completion = RedisDurableGameCoopCommand.completeObjective(
            objectiveID: "restore-power",
            playerID: playerID,
            publicState: Data("powered".utf8),
            privatePlayerState: Data("fuse-location".utf8)
        )
        _ = try await mission.commit(commandID: completionID, playerID: playerID, command: completion)
        let action = GameCoopScheduledNPCAction(npcID: "stalker", dueTick: 3, payload: Data("move".utf8))
        _ = try await mission.commit(commandID: UUID(), playerID: playerID, command: .scheduleNPCAction(action))
        let stageID = UUID()
        let staged = try await mission.stageNPCActions(commandID: stageID, playerID: playerID, tick: 3)
        #expect(staged.batch.actions == [action])
        #expect(try await store.releaseLease(firstLease))

        let takeover = try await store.acquireLease(sessionID: sessionID)
        let restored = try await RedisDurableGameCoopSession.open(
            sessionID: sessionID,
            lease: takeover,
            store: store,
            configuration: durableConfiguration
        )
        let recovered = try await restored.snapshot(for: playerID)
        #expect(recovered.completedObjectives == ["restore-power"])
        #expect(recovered.privatePlayerState[playerID] == Data("fuse-location".utf8))
        #expect(try await restored.pendingNPCActionBatch().actions == [action])
        let ack = try await restored.acknowledgeNPCActions(
            commandID: UUID(), playerID: playerID, actionIDs: [action.id]
        )
        #expect(ack.sequence == 6)
        let duplicate = try await restored.commit(commandID: completionID, playerID: playerID, command: completion)
        #expect(duplicate.isDuplicate)
        #expect(duplicate.sequence == 3)
        try await store.stop()
    } catch {
        try? await store.stop()
        throw error
    }
}

/// Run in separate processes around a forced Redis restart with AOF enabled.
/// The scenario checkpoints a durable co-op session, then leaves mission and NPC
/// outbox commands in the journal suffix for recovery and redelivery.
@Test func redisDurableCoopSessionSurvivesProcessAndRedisRestartWithAOF() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_HOST"],
          let phase = ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_COOP_CRASH_PHASE"] else { return }
    guard phase == "write" || phase == "recover",
          let prefix = ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_COOP_CRASH_PREFIX"],
          !prefix.isEmpty else { throw RedisGameStateRecoveryError.invalidConfiguration }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_PORT"] ?? "6379") ?? 6379
    let store = RedisGameStateRecoveryStore(configuration: try RedisGameStateRecoveryConfiguration(
        host: host, port: port, keyPrefix: prefix, maximumRecordBytes: 1_048_576,
        maximumRecoveryBytes: 2_097_152
    ))
    try await store.start()
    let sessionID = UUID(uuidString: "783bc7ec-73d9-4ab2-ae70-789b9b13f5df")!
    let playerID = UUID(uuidString: "073e8b9f-83ce-40c0-ad14-26393b9f278e")!
    let joinID = UUID(uuidString: "f921f074-33fc-45cb-b57c-e7c00bc48dd1")!
    let startID = UUID(uuidString: "a2d4fa11-2a8e-48d5-b185-2e4d052eb058")!
    let randomDecisionID = UUID(uuidString: "20454f30-6df4-4dc7-ae18-adea8c88fa70")!
    let completeID = UUID(uuidString: "cf1b7010-859f-49f2-92d1-d9e0dd8cad57")!
    let scheduleID = UUID(uuidString: "c5be5a4f-3c47-48a8-a534-bfcd0c346a82")!
    let stageID = UUID(uuidString: "ca3afdae-e6bd-4408-b00c-a0521dfffe7d")!
    let action = GameCoopScheduledNPCAction(
        id: UUID(uuidString: "24372825-217a-4e98-8920-980adcd77af1")!,
        npcID: "stalker", dueTick: 9, payload: Data("move-to-east-hall".utf8)
    )
    let commandConfiguration = try RedisDurableGameCommandConfiguration(
        maximumStateBytes: 1_048_576, maximumCommandBytes: 65_536, maximumProcessedCommands: 128,
        maximumReplayEvents: 1_000, maximumCheckpointBytes: 1_048_576
    )
    do {
        if phase == "write" {
            if try await store.load(sessionID: sessionID) != nil {
                Issue.record("use a fresh Redis key prefix for the durable co-op crash test")
            }
            let lease = try await store.acquireLease(sessionID: sessionID, durationMilliseconds: 1_000)
            let game = try GameCoopSession(
                sessionID: sessionID, objectives: ["restore-power"], deterministicSeed: 0xC0FFEE
            )
            let mission = try await RedisDurableGameCoopSession.open(
                initialSession: game, lease: lease, store: store, configuration: commandConfiguration
            )
            _ = try await mission.commit(commandID: joinID, playerID: playerID, command: .join(playerID: playerID))
            _ = try await mission.commit(commandID: startID, playerID: playerID, command: .start)
            let decision = try await mission.deterministicDecision(commandID: randomDecisionID, playerID: playerID)
            #expect(decision.receipt.sequence == 3)
            #expect(decision.value == 9_781_417_775_987_323_851)
            try await mission.checkpoint()
            _ = try await mission.commit(
                commandID: completeID, playerID: playerID,
                command: .completeObjective(
                    objectiveID: "restore-power", playerID: playerID,
                    publicState: Data("powered".utf8), privatePlayerState: Data("fuse-room".utf8)
                )
            )
            _ = try await mission.commit(commandID: scheduleID, playerID: playerID, command: .scheduleNPCAction(action))
            let staged = try await mission.stageNPCActions(
                commandID: stageID, playerID: playerID, tick: 9
            )
            #expect(staged.receipt.sequence == 6)
            #expect(staged.batch.actions == [action])
        } else {
            var lease: GameStateSessionLease?
            for attempt in 0..<30 {
                do {
                    lease = try await store.acquireLease(
                        sessionID: sessionID, durationMilliseconds: 5_000
                    )
                    break
                } catch RedisGameStateRecoveryError.leaseHeld where attempt < 29 {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            let takeover = try #require(lease)
            #expect(takeover.epoch >= 2)
            let mission = try await RedisDurableGameCoopSession.open(
                sessionID: sessionID, lease: takeover, store: store, configuration: commandConfiguration
            )
            let recovered = try await mission.snapshot(for: playerID)
            #expect(recovered.completedObjectives == ["restore-power"])
            #expect(recovered.privatePlayerState[playerID] == Data("fuse-room".utf8))
            let decision = try await mission.deterministicDecision(commandID: randomDecisionID, playerID: playerID)
            #expect(decision.receipt.isDuplicate)
            #expect(decision.receipt.sequence == 3)
            #expect(decision.value == 9_781_417_775_987_323_851)
            let retriedStage = try await mission.stageNPCActions(
                commandID: stageID, playerID: playerID, tick: 9
            )
            #expect(retriedStage.receipt.isDuplicate)
            #expect(retriedStage.receipt.sequence == 6)
            #expect(retriedStage.batch.actions == [action])
            let ackID = UUID(uuidString: "dafb0a23-6610-468c-b341-8b493013f78b")!
            let ack = try await mission.acknowledgeNPCActions(
                commandID: ackID, playerID: playerID, actionIDs: [action.id]
            )
            #expect(ack.sequence == 7)
            #expect(try await mission.pendingNPCActionBatch().actions.isEmpty)
            #expect(try await mission.acknowledgeNPCActions(
                commandID: ackID, playerID: playerID, actionIDs: [action.id]
            ).isDuplicate)
        }
        try await store.stop()
    } catch {
        try? await store.stop()
        throw error
    }
}

/// Run in separate test processes before and after a forced Redis restart with AOF enabled.
/// Set PEARFY_TEST_GAME_REDIS_CRASH_PHASE=write, kill/restart Redis, then use `recover`.
@Test func redisRecoverySurvivesProcessAndRedisRestartWithAOF() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_HOST"],
          let phase = ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_CRASH_PHASE"] else { return }
    guard phase == "write" || phase == "recover",
          let prefix = ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_CRASH_PREFIX"],
          !prefix.isEmpty else {
        throw RedisGameStateRecoveryError.invalidConfiguration
    }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_PORT"] ?? "6379") ?? 6379
    let configuration = try RedisGameStateRecoveryConfiguration(
        host: host,
        port: port,
        keyPrefix: prefix,
        maximumRecordBytes: 1_048_576,
        maximumRecoveryBytes: 2_097_152
    )
    let store = RedisGameStateRecoveryStore(configuration: configuration)
    try await store.start()

    let sessionID = UUID(uuidString: "a4ae7b84-e84b-4e19-b38a-4ee9dc4dc6f7")!
    let playerID = UUID(uuidString: "51b3ce68-2a9f-4de9-9be0-0420fd1ca117")!
    let commandID = UUID(uuidString: "71d49c6b-593a-44da-8a6d-a47ae2bce7b8")!
    let disconnectTime = Date(timeIntervalSince1970: 1_800_000_000)
    let ownerID = UUID(uuidString: phase == "write"
        ? "e587d49e-4fd3-47d9-a52a-008cffce522a"
        : "845e5c3b-8480-4cf4-80a8-1277a343e850")!
    do {
        if phase == "write" {
            if try await store.load(sessionID: sessionID) != nil {
                Issue.record("use a fresh Redis key prefix for the write phase")
            }
            let lease = try await store.acquireLease(sessionID: sessionID, ownerID: ownerID, durationMilliseconds: 1_000)
            let gameSession = try GameCoopSession(
                sessionID: sessionID,
                objectives: ["evidence", "extract"],
                objectivePrerequisites: ["extract": ["evidence"]],
                objectiveProgressTargets: ["evidence": 3],
                deterministicSeed: 0xC0FFEE
            )
            try await gameSession.join(playerID: playerID)
            try await gameSession.start()
            _ = try await gameSession.recordObjectiveProgress(
                "evidence", by: 1, commandID: commandID, playerID: playerID,
                publicState: Data("public-evidence".utf8), privatePlayerState: Data("private-evidence".utf8)
            )
            _ = try await gameSession.nextDeterministicValue()
            try await gameSession.scheduleNPCAction(GameCoopScheduledNPCAction(
                id: UUID(uuidString: "52c1a291-4d62-4de9-9c54-3ed8c1abc001")!,
                npcID: "stalker", dueTick: 5, payload: Data("approach".utf8)
            ))
            try await gameSession.disconnect(playerID: playerID, gracePeriodMilliseconds: 60_000, now: disconnectTime)
            let sessionCheckpoint = try await gameSession.recoveryCheckpoint()
            let checkpoint = GameStateCheckpoint(revision: 0, state: sessionCheckpoint.data, events: [])
            try await store.save(sessionID: sessionID, epoch: lease.epoch, checkpoint: checkpoint)
            try await store.append(
                sessionID: sessionID,
                epoch: lease.epoch,
                event: GameStateEvent(
                    sequence: 1,
                    commandID: commandID,
                    playerID: playerID,
                    payload: Data("event-after-checkpoint".utf8),
                    state: Data("state-after-event".utf8)
                )
            )
        } else {
            var recoveredLease: GameStateSessionLease?
            for attempt in 0..<30 {
                do {
                    recoveredLease = try await store.acquireLease(
                        sessionID: sessionID,
                        ownerID: ownerID,
                        durationMilliseconds: 5_000
                    )
                    break
                } catch RedisGameStateRecoveryError.leaseHeld where attempt < 29 {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            let lease = try #require(recoveredLease)
            #expect(lease.epoch >= 2)
            let recovered = try #require(try await store.load(sessionID: sessionID))
            #expect(recovered.epoch == lease.epoch)
            #expect(recovered.checkpoint.revision == 0)
            let gameSession = try GameCoopSession(restoringCheckpoint: recovered.checkpoint.state)
            #expect(await gameSession.disconnectedMemberCount == 1)
            try await gameSession.reconnect(playerID: playerID, now: disconnectTime.addingTimeInterval(30))
            let snapshot = try await gameSession.snapshot(for: playerID)
            #expect(snapshot.phase == .active)
            #expect(snapshot.revision == 7)
            #expect(snapshot.objectiveProgress == ["evidence": 1])
            #expect(snapshot.deterministicDrawCount == 1)
            #expect(snapshot.privatePlayerState[playerID] == Data("private-evidence".utf8))
            #expect(!(try await gameSession.recordObjectiveProgress(
                "evidence", by: 1, commandID: commandID, playerID: playerID,
                publicState: Data("public-evidence".utf8), privatePlayerState: Data("private-evidence".utf8)
            )))
            #expect(await gameSession.queuedNPCActionCount == 1)
            let resumedActions = try await gameSession.advanceNPCSchedule(to: 5)
            #expect(resumedActions.actions.map(\.payload) == [Data("approach".utf8)])
            #expect(recovered.latestSequence == 1)
            #expect(recovered.events.count == 1)
            #expect(recovered.events.first?.sequence == 1)
            #expect(recovered.events.first?.payload == Data("event-after-checkpoint".utf8))
            #expect(recovered.events.first?.state == Data("state-after-event".utf8))
        }
        try await store.stop()
    } catch {
        try? await store.stop()
        throw error
    }
}

@Test func redisRecoveryReadsJournalInBoundedPagesAcrossMultipleRanges() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_PORT"] ?? "6379") ?? 6379
    let prefix = "pearfy-game-pages-test-\(UUID().uuidString.lowercased())"
    let configuration = try RedisGameStateRecoveryConfiguration(
        host: host,
        port: port,
        keyPrefix: prefix,
        maximumEventsPerSession: 300,
        maximumRecordBytes: 16_384,
        maximumRecoveryBytes: 8_388_608
    )
    let store = RedisGameStateRecoveryStore(configuration: configuration)
    try await store.start()
    defer { Task { try? await store.stop() } }

    let sessionID = UUID()
    let lease = try await store.acquireLease(sessionID: sessionID)
    try await store.save(
        sessionID: sessionID,
        epoch: lease.epoch,
        checkpoint: GameStateCheckpoint(revision: 0, state: Data([0]), events: [])
    )
    let playerID = UUID()
    for sequence in 1...257 {
        let bytes = Data(repeating: UInt8(truncatingIfNeeded: sequence), count: 32)
        try await store.append(
            sessionID: sessionID,
            epoch: lease.epoch,
            event: GameStateEvent(
                sequence: UInt64(sequence), commandID: UUID(), playerID: playerID, payload: bytes, state: bytes
            )
        )
    }

    let recovered = try #require(try await store.load(sessionID: sessionID))
    #expect(recovered.events.count == 257)
    #expect(recovered.events.first?.sequence == 1)
    #expect(recovered.events.last?.sequence == 257)
    #expect(recovered.latestSequence == 257)

    let orphanSessionID = UUID()
    let orphanLease = try await store.acquireLease(sessionID: orphanSessionID)
    try await store.append(
        sessionID: orphanSessionID,
        epoch: orphanLease.epoch,
        event: GameStateEvent(sequence: 1, commandID: UUID(), playerID: playerID, payload: Data([1]), state: Data([1]))
    )
    do {
        _ = try await store.load(sessionID: orphanSessionID)
        Issue.record("journal entries without a checkpoint must fail closed")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .invalidResponse)
    }
    try await store.stop()
}

@Test func redisRecoveryLeaseFencesFormerOwnerAndRequiresActiveLease() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_PORT"] ?? "6379") ?? 6379
    let prefix = "pearfy-game-lease-test-\(UUID().uuidString.lowercased())"
    let configuration = try RedisGameStateRecoveryConfiguration(host: host, port: port, keyPrefix: prefix)
    let store = RedisGameStateRecoveryStore(configuration: configuration)
    try await store.start()
    defer { Task { try? await store.stop() } }

    let sessionID = UUID()
    let playerID = UUID()
    let first = GameStateEvent(sequence: 1, commandID: UUID(), playerID: playerID, payload: Data([1]), state: Data([1]))
    do {
        try await store.append(sessionID: sessionID, epoch: 1, event: first)
        Issue.record("journal writes require a live session lease")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .leaseExpired)
    }
    do {
        try await store.save(sessionID: sessionID, epoch: 1, checkpoint: GameStateCheckpoint(revision: 0, state: Data(), events: []))
        Issue.record("checkpoint writes require a live session lease")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .leaseExpired)
    }

    let oldOwner = try await store.acquireLease(sessionID: sessionID)
    #expect(oldOwner.epoch == 1)
    #expect(try await store.renewLease(oldOwner))
    do {
        _ = try await store.acquireLease(sessionID: sessionID)
        Issue.record("a second process cannot acquire an active session lease")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .leaseHeld)
    }
    try await store.append(sessionID: sessionID, epoch: oldOwner.epoch, event: first)
    #expect(try await store.releaseLease(oldOwner))

    let newOwner = try await store.acquireLease(sessionID: sessionID)
    #expect(newOwner.epoch == oldOwner.epoch + 1)
    #expect(!(try await store.renewLease(oldOwner)))
    let stale = GameStateEvent(sequence: 2, commandID: UUID(), playerID: playerID, payload: Data([2]), state: Data([2]))
    do {
        try await store.append(sessionID: sessionID, epoch: oldOwner.epoch, event: stale)
        Issue.record("a released process cannot append after fencing advances")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .staleEpoch)
    }
    try await store.append(sessionID: sessionID, epoch: newOwner.epoch, event: stale)

    let expiringSessionID = UUID()
    let expiringOwner = try await store.acquireLease(sessionID: expiringSessionID, durationMilliseconds: 1_000)
    try await Task.sleep(for: .milliseconds(1_100))
    let takeover = try await store.acquireLease(sessionID: expiringSessionID)
    #expect(takeover.epoch == expiringOwner.epoch + 1)
    #expect(!(try await store.renewLease(expiringOwner)))
    do {
        try await store.append(sessionID: expiringSessionID, epoch: expiringOwner.epoch, event: first)
        Issue.record("an expired owner cannot append after lease takeover")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .staleEpoch)
    }
}

@Test func redisRecoveryRejectsUncheckpointedJournalOverflowAndResumesAfterCheckpoint() async throws {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_HOST"] else { return }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_PORT"] ?? "6379") ?? 6379
    let prefix = "pearfy-game-capacity-test-\(UUID().uuidString.lowercased())"
    let configuration = try RedisGameStateRecoveryConfiguration(
        host: host,
        port: port,
        password: ProcessInfo.processInfo.environment["PEARFY_TEST_GAME_REDIS_PASSWORD"],
        keyPrefix: prefix,
        maximumEventsPerSession: 1
    )
    let store = RedisGameStateRecoveryStore(configuration: configuration)
    try await store.start()
    defer { Task { try? await store.stop() } }

    let sessionID = UUID()
    let lease = try await store.acquireLease(sessionID: sessionID)
    let playerID = UUID()
    let first = GameStateEvent(sequence: 1, commandID: UUID(), playerID: playerID, payload: Data([1]), state: Data([11]))
    let second = GameStateEvent(sequence: 2, commandID: UUID(), playerID: playerID, payload: Data([2]), state: Data([22]))
    try await store.append(sessionID: sessionID, epoch: lease.epoch, event: first)
    try await store.append(sessionID: sessionID, epoch: lease.epoch, event: first)
    let gap = GameStateEvent(sequence: 3, commandID: UUID(), playerID: playerID, payload: Data([3]), state: Data([33]))
    do {
        try await store.append(sessionID: sessionID, epoch: lease.epoch, event: gap)
        Issue.record("the journal must reject a sequence gap")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .sequenceConflict)
    }
    do {
        try await store.append(sessionID: sessionID, epoch: lease.epoch, event: second)
        Issue.record("the journal must not trim an event that has not reached a checkpoint")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .journalCapacityReached)
    }

    try await store.save(
        sessionID: sessionID,
        epoch: lease.epoch,
        checkpoint: GameStateCheckpoint(revision: 1, state: Data([1]), events: [])
    )
    try await store.append(sessionID: sessionID, epoch: lease.epoch, event: second)
    let restored = try #require(try await store.load(sessionID: sessionID))
    #expect(restored.epoch == lease.epoch)
    #expect(restored.checkpoint.revision == 1)
    #expect(restored.events == [second])
    #expect(restored.latestSequence == 2)
    let third = GameStateEvent(sequence: 3, commandID: UUID(), playerID: playerID, payload: Data([3]), state: Data([33]))
    do {
        try await store.append(sessionID: sessionID, epoch: lease.epoch, event: third)
        Issue.record("the post-checkpoint journal remains bounded to one event")
    } catch {
        #expect(error as? RedisGameStateRecoveryError == .journalCapacityReached)
    }
    try await store.stop()
}

@Test func gameStateDevKitRouteRequiresBearerAndShowsPagedRecords() async throws {
    let manager = GameServerStateManager(maximumRetainedStates: 5, maximumPendingUpdates: 8)
    try await manager.start()
    let publisher = try await manager.publisher()
    let record = try GameServerStateRecord(namespace: "match", key: "state", revision: 4, payload: Data("{\"phase\":\"active\"}".utf8))
    _ = publisher.publish(record)
    for _ in 0..<30 {
        if !(await manager.snapshot().isEmpty) { break }
        try await Task.sleep(for: .milliseconds(5))
    }

    let router = HTTPRouter()
    try await PearfyGameServerDevKit.install(
        on: router,
        configuration: DevKitConfiguration(enabled: true, bearerToken: "local-devkit-token-1234"),
        manager: manager
    )
    try await router.freeze()
    let path = "/__pearfy/devkit/api/game-states?offset=0&limit=1"
    let unauthorized = await router.handle(try HTTPRequest(method: .get, target: path))
    #expect(unauthorized.status == 401)
    let response = await router.handle(try HTTPRequest(method: .get, target: path, headers: ["authorization": "Bearer local-devkit-token-1234"]))
    #expect(response.status == 200)
    let page = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    #expect(page["total"] as? Int == 1)
    let states = try #require(page["states"] as? [[String: Any]])
    let state = try #require(states.first)
    #expect(state["id"] as? String == "match/state")
    #expect(state["revision"] as? Int == 4)
    await manager.stop()
}

@Test func stateMiddlewareRetriesOffPathAndFlushesOnShutdown() async throws {
    let manager = GameServerStateManager(maximumRetainedStates: 4, maximumPendingUpdates: 4)
    let sink = RetryGameStateSink()
    let middleware = GameServerStateClosureMiddleware { record in try await sink.persist(record) }
    let retryPolicy = try GameServerStateRetryPolicy(maximumRetries: 2, initialBackoffMilliseconds: 1, maximumBackoffMilliseconds: 2)
    try await manager.start(middlewares: [middleware], retryPolicy: retryPolicy)
    let publisher = try await manager.publisher()
    let record = try GameServerStateRecord(namespace: "zone", key: "checkpoint", revision: 1, payload: Data([1]))
    #expect(publisher.publish(record) == .enqueued)
    await manager.stop()
    let attempts = await sink.attemptCount
    let writes = await sink.persistedCount
    let metrics = await manager.metrics()
    #expect(attempts == 3)
    #expect(writes == 1)
    #expect(metrics.middlewareFailureCount == 0)
}

@Test func concurrentStateManagerStopsWaitForTheSameMiddlewareDrain() async throws {
    let manager = GameServerStateManager(maximumRetainedStates: 4, maximumPendingUpdates: 4)
    let sink = DelayedFlushGameStateSink()
    try await manager.start(middlewares: [GameServerStateClosureMiddleware(
        persist: { _ in try await sink.persist() },
        flush: { await sink.flush() }
    )])
    let publisher = try await manager.publisher()
    _ = publisher.publish(try GameServerStateRecord(namespace: "room", key: "state", revision: 1, payload: Data([1])))

    async let firstStop: Void = manager.stop()
    try await Task.sleep(for: .milliseconds(5))
    async let secondStop: Void = manager.stop()
    _ = await (firstStop, secondStop)

    #expect(await sink.flushCount == 1)
    #expect(await manager.metrics().activeMiddlewareCount == 0)
}

private actor MemoryGameStateRecoveryStore: GameStateRecoveryStore {
    private(set) var sessionID: UUID?
    private var epoch: UInt64?
    private var checkpoint: GameStateCheckpoint?
    private var events: [GameStateEvent] = []
    private(set) var savedCheckpointCount = 0
    var eventCount: Int { events.count }
    func append(sessionID: UUID, epoch: UInt64, event: GameStateEvent) async throws {
        if let current = self.epoch, current != epoch { throw RedisGameStateRecoveryError.staleEpoch }
        self.sessionID = sessionID; self.epoch = epoch; events.append(event)
    }
    func save(sessionID: UUID, epoch: UInt64, checkpoint: GameStateCheckpoint) async throws {
        if let current = self.epoch, current != epoch { throw RedisGameStateRecoveryError.staleEpoch }
        self.sessionID = sessionID; self.epoch = epoch; self.checkpoint = checkpoint; savedCheckpointCount += 1
    }
    func load(sessionID: UUID) async throws -> (epoch: UInt64, checkpoint: GameStateCheckpoint, events: [GameStateEvent], latestSequence: UInt64)? {
        guard let epoch, let checkpoint else { return nil }
        let recovered = events.filter { $0.sequence > checkpoint.revision }
        return (epoch, checkpoint, recovered, recovered.last?.sequence ?? checkpoint.revision)
    }
}

private actor DurableCommandMemoryStore: GameStateRecoveryStore {
    private var epoch: UInt64?
    private var checkpoint: GameStateCheckpoint?
    private var events: [GameStateEvent] = []
    private var failAfterNextAppend = false
    private var pauseNext = false
    private var appendPaused = false
    private var appendContinuation: CheckedContinuation<Void, Never>?
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    func failNextAppendAfterCommit() { failAfterNextAppend = true }
    func pauseNextAppend() { pauseNext = true }
    func waitForPausedAppend() async {
        if appendPaused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }
    func resumeAppend() {
        appendContinuation?.resume()
        appendContinuation = nil
    }
    func takeover(epoch: UInt64) { self.epoch = epoch }

    func append(sessionID: UUID, epoch: UInt64, event: GameStateEvent) async throws {
        if let current = self.epoch, current != epoch { throw RedisGameStateRecoveryError.staleEpoch }
        if pauseNext {
            pauseNext = false
            appendPaused = true
            let waiters = pauseWaiters
            pauseWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { appendContinuation = $0 }
            appendPaused = false
        }
        if let previous = events.last, previous.sequence == event.sequence {
            guard previous == event else { throw RedisGameStateRecoveryError.sequenceConflict }
            if failAfterNextAppend { failAfterNextAppend = false; throw RedisGameStateRecoveryError.journalUnavailable }
            return
        }
        let latest = events.last?.sequence ?? checkpoint?.revision ?? 0
        guard event.sequence == latest + 1 else { throw RedisGameStateRecoveryError.sequenceConflict }
        self.epoch = epoch
        events.append(event)
        if failAfterNextAppend {
            failAfterNextAppend = false
            throw RedisGameStateRecoveryError.journalUnavailable
        }
    }

    func save(sessionID: UUID, epoch: UInt64, checkpoint: GameStateCheckpoint) async throws {
        if let current = self.epoch, current != epoch { throw RedisGameStateRecoveryError.staleEpoch }
        let latest = events.last?.sequence ?? self.checkpoint?.revision ?? 0
        guard checkpoint.revision <= latest else { throw RedisGameStateRecoveryError.sequenceConflict }
        self.epoch = epoch
        self.checkpoint = checkpoint
    }

    func load(sessionID: UUID) async throws -> (epoch: UInt64, checkpoint: GameStateCheckpoint, events: [GameStateEvent], latestSequence: UInt64)? {
        guard let epoch, let checkpoint else { return nil }
        let recovered = events.filter { $0.sequence > checkpoint.revision }
        return (epoch, checkpoint, recovered, events.last?.sequence ?? checkpoint.revision)
    }
}

private actor SchedulerCaptureCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor DelayedFlushGameStateSink {
    private(set) var flushCount = 0
    func persist() async throws { try await Task.sleep(for: .milliseconds(30)) }
    func flush() async {
        try? await Task.sleep(for: .milliseconds(30))
        flushCount += 1
    }
}

private actor CapturedGameStateSink {
    private(set) var records: [GameServerStateRecord] = []
    func persist(_ record: GameServerStateRecord) { records.append(record) }
}

private actor AsyncGameReducerGate {
    private var isPaused = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseUntilReleased() async {
        isPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
        isPaused = false
    }

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor RetryGameStateSink {
    private var attempts = 0
    private var writes = 0
    var attemptCount: Int { attempts }
    var persistedCount: Int { writes }
    func persist(_ record: GameServerStateRecord) throws {
        attempts += 1
        if attempts < 3 { throw GameServerError.capacityReached }
        writes += 1
    }
}

@Test func gameServerCLIWritesJSONTemplateWithoutOverwriting() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pearfy-gameserver-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let output = directory.appendingPathComponent("high.json")
    #expect(try PearfyGameServerCommand.run(["template", "--mode", "high", "--output", output.path], currentDirectory: directory) == 0)
    let profile = try JSONDecoder().decode(GameServerModeProfile.self, from: Data(contentsOf: output))
    #expect(profile.mode == .high)
    #expect(!profile.udpEnabled)
    #expect(profile.fixedStep?.tickRateHz == 60)
    #expect(profile.fixedStep?.maximumInputsPerTick == 8_192)
    #expect(throws: (any Error).self) {
        try PearfyGameServerCommand.run(["template", "--mode", "light", "--output", output.path], currentDirectory: directory)
    }
}

@Test func gameServerCLIGeneratesGenreRecipesWithExplicitApplicationGates() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pearfy-gameserver-recipes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    for recipe in GameServerRecipe.allCases {
        let output = directory.appendingPathComponent("\(recipe.rawValue).json")
        #expect(try PearfyGameServerCommand.run(["recipe", recipe.rawValue, "--output", output.path], currentDirectory: directory) == 0)
        let profile = try JSONDecoder().decode(GameServerRecipeProfile.self, from: Data(contentsOf: output))
        #expect(profile.recipe == recipe)
        #expect(profile.requiredModules.contains("gameserver"))
        #expect(profile.requiredModules.contains("gameserver-grpc"))
        #expect(profile.requiredModules.contains("gameserver-transport"))
        #expect(!profile.applicationResponsibilities.isEmpty)
        #expect(!profile.productionGates.isEmpty)
        #expect(throws: (any Error).self) {
            try PearfyGameServerCommand.run(["recipe", recipe.rawValue, "--output", output.path], currentDirectory: directory)
        }
    }

    let fps = GameServerRecipeProfile.preset(.fps)
    let mmo = GameServerRecipeProfile.preset(.mmo)
    #expect(fps.mode == .high)
    #expect(mmo.mode == .high)
    #expect(GameServerModeProfile.preset(.high).udpEnabled == false)
    #expect(fps.requiredModules.contains("gameserver-realtime"))
    #expect(mmo.requiredModules.contains("gameserver-world-postgres"))
    #expect(GameServerRecipeProfile.preset(.friendslop).applicationResponsibilities.contains { $0.localizedCaseInsensitiveContains("NPC") })
    #expect(GameServerRecipeProfile.preset(.friendslop).optionalModules.contains("gameserver-threat-director"))
    #expect(GameServerRecipeProfile.preset(.friendslop).optionalModules.contains("gameserver-npc-learn"))
    #expect(GameServerRecipeProfile.preset(.turnBased).capabilities.contains { $0.contains("write-ahead commit") })
    #expect(GameServerRecipeProfile.preset(.turnBased).requiredModules.contains("gameserver-turn-based"))
    #expect(GameServerRecipeProfile.preset(.turnBased).optionalModules.contains("gameserver-turn-based-postgres"))
    #expect(GameServerRecipeProfile.preset(.turnBased).optionalModules.contains("gameserver-turn-based-redis"))
    #expect(GameServerRecipeProfile.preset(.turnBased).capabilities.contains { $0.contains("append-before-publish") })
    #expect(GameServerRecipeProfile.preset(.friendslop).capabilities.contains { $0.contains("write-ahead commit") })
}

@Test func gameServerCLIListsRegistryBackedModuleStatus() throws {
    #expect(try PearfyGameServerCommand.run(["modules"]) == 0)
}

@Test func gameServerRedisRecoveryCLIPlansAndAppliesWithoutEmbeddingCredentials() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-gameserver-recovery-cli-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let frameworkRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let projectRoot = root.appendingPathComponent("sample-api", isDirectory: true)
    _ = try ProjectScaffolder(frameworkRoot: frameworkRoot).createProject(named: "sample-api", at: projectRoot)
    let moduleManager = try PearfyModuleManager()
    try moduleManager.apply(try moduleManager.planAdding("gameserver", to: ["http"]), to: projectRoot)
    try moduleManager.apply(try moduleManager.planAdding("redis", to: ["http", "gameserver"]), to: projectRoot)

    let configURL = projectRoot.appendingPathComponent(".pearfy/gameserver-recovery.json")
    #expect(try PearfyGameServerCommand.run(["recovery", "--store", "redis"], currentDirectory: projectRoot) == 0)
    #expect(!FileManager.default.fileExists(atPath: configURL.path))
    #expect(try !moduleManager.doctor(projectRoot: projectRoot).contains("gameserver-redis-recovery"))

    #expect(try PearfyGameServerCommand.run(
        ["recovery", "--store", "redis", "--apply"], currentDirectory: projectRoot
    ) == 0)
    #expect(try moduleManager.doctor(projectRoot: projectRoot).contains("gameserver-redis-recovery"))
    let bytes = try Data(contentsOf: configURL)
    let profile = try JSONDecoder().decode(GameServerRecoveryProfile.self, from: bytes)
    #expect(profile.schemaVersion == 3)
    #expect(profile.store == "redis-streams-and-checkpoints")
    #expect(profile.connection.defaultHost == "127.0.0.1")
    #expect(profile.connection.defaultPort == 6379)
    #expect(profile.connection.tlsRequiredForRemoteHosts)
    #expect(profile.connection.passwordEnvironmentVariable == "PEARFY_GAME_REDIS_PASSWORD")
    #expect(profile.limits.maximumEventsPerSession == 100_000)
    #expect(profile.limits.maximumRecordBytes == 2_097_152)
    #expect(profile.limits.maximumPendingStateBytesPerQueue == 1_048_576)
    #expect(profile.tickWriter.maximumPendingBatches == 32)
    #expect(profile.tickWriter.maximumPendingBytes == 16_777_216)
    #expect(profile.tickWriter.maximumTicksPerBatch == 120)
    #expect(profile.tickWriter.maximumBatchBytes == 1_048_576)
    #expect(profile.limits.checkpointEveryEvents == 100)
    #expect(profile.limits.checkpointIntervalMilliseconds == 30_000)
    #expect(profile.lease.durationMilliseconds == 15_000)
    #expect(profile.persistence.delivery.contains("best-effort-async"))
    #expect(profile.persistence.durableCommandCommit.contains("resulting-state digest"))
    #expect(profile.persistence.durableTickBatchCommit.contains("before publication"))
    #expect(profile.persistence.commandAppendFailure.contains("retry the same command ID"))
    #expect(profile.persistence.guaranteedRecoveryPointObjective.hasPrefix("none;"))
    #expect(!String(decoding: bytes, as: UTF8.self).contains("secret-value"))
}

@Test func gameServerRecoveryCLIRequiresGameServerAndRedisBeforePlanning() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-gameserver-recovery-prerequisite-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let frameworkRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let projectRoot = root.appendingPathComponent("sample-api", isDirectory: true)
    _ = try ProjectScaffolder(frameworkRoot: frameworkRoot).createProject(named: "sample-api", at: projectRoot)
    #expect(throws: (any Error).self) {
        try PearfyGameServerCommand.run(["recovery", "--store", "redis"], currentDirectory: projectRoot)
    }
    #expect(try PearfyModuleManager().doctor(projectRoot: projectRoot) == ["http"])
}

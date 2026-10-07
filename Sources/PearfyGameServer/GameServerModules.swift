import Foundation
import Crypto

// MARK: - Rooms

public struct GameRoomConfiguration: Sendable, Equatable {
    public let maximumRooms: Int
    public let maximumMembersPerRoom: Int
    public let inviteLifetime: TimeInterval
    public let reconnectGracePeriod: TimeInterval
    public let maximumInvites: Int
    public static let standard = GameRoomConfiguration(maximumRooms: 1_000, maximumMembersPerRoom: 16, inviteLifetime: 300, reconnectGracePeriod: 60, maximumInvites: 20_000, standard: ())

    public init(maximumRooms: Int = 1_000, maximumMembersPerRoom: Int = 16,
                inviteLifetime: TimeInterval = 300, reconnectGracePeriod: TimeInterval = 60,
                maximumInvites: Int = 20_000) throws {
        guard (1...1_000_000).contains(maximumRooms), (1...10_000).contains(maximumMembersPerRoom),
              inviteLifetime.isFinite, (1...86_400).contains(inviteLifetime),
              reconnectGracePeriod.isFinite, (0...3_600).contains(reconnectGracePeriod),
              (1...1_000_000).contains(maximumInvites) else {
            throw GameServerError.invalidConfiguration
        }
        self.maximumRooms = maximumRooms
        self.maximumMembersPerRoom = maximumMembersPerRoom
        self.inviteLifetime = inviteLifetime
        self.reconnectGracePeriod = reconnectGracePeriod
        self.maximumInvites = maximumInvites
    }
    private init(maximumRooms: Int, maximumMembersPerRoom: Int, inviteLifetime: TimeInterval, reconnectGracePeriod: TimeInterval, maximumInvites: Int, standard: Void) {
        self.maximumRooms = maximumRooms; self.maximumMembersPerRoom = maximumMembersPerRoom
        self.inviteLifetime = inviteLifetime; self.reconnectGracePeriod = reconnectGracePeriod; self.maximumInvites = maximumInvites
    }
}

public struct GameRoomSnapshot: Sendable, Equatable, Identifiable {
    public enum Visibility: String, Sendable, Codable { case `public`, `private` }
    public let id: UUID
    public let ownerID: UUID
    public let visibility: Visibility
    public let members: Set<UUID>
    public let disconnectedUntil: [UUID: Date]
    public let revision: UInt64
}

/// Privacy-safe entry used for public room discovery; member identities are never listed.
public struct GameRoomListing: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let memberCount: Int
    public let maximumMembers: Int
    public let revision: UInt64
}

/// Bounded, process-local room manager. Multi-replica consistency requires a store adapter.
public actor GameRoomManager {
    private struct Room: Sendable {
        var ownerID: UUID
        var visibility: GameRoomSnapshot.Visibility
        var members: Set<UUID>
        var disconnectedUntil: [UUID: Date] = [:]
        var revision: UInt64 = 0
    }
    private struct Invite: Sendable { let roomID: UUID; let playerID: UUID; let expiresAt: Date }
    private let configuration: GameRoomConfiguration
    private var rooms: [UUID: Room] = [:]
    private var invites: [String: Invite] = [:]
    private var publicRoomOrder: [UUID] = []

    public init(configuration: GameRoomConfiguration = .standard) {
        self.configuration = configuration
    }

    public func create(ownerID: UUID, visibility: GameRoomSnapshot.Visibility = .private) throws -> GameRoomSnapshot {
        guard rooms.count < configuration.maximumRooms else { throw GameServerError.capacityReached }
        let id = UUID()
        let room = Room(ownerID: ownerID, visibility: visibility, members: [ownerID])
        rooms[id] = room
        if visibility == .public { publicRoomOrder.append(id) }
        return snapshot(id, room)
    }

    public func invite(roomID: UUID, by ownerID: UUID, playerID: UUID, now: Date = Date()) throws -> String {
        invites = invites.filter { $0.value.expiresAt > now }
        removeExpiredMembers(in: roomID, now: now)
        guard let room = rooms[roomID], room.ownerID == ownerID else { throw GameServerError.roomNotFoundOrUnauthorized }
        guard room.members.count < configuration.maximumMembersPerRoom else { throw GameServerError.roomFull }
        guard invites.count < configuration.maximumInvites else { throw GameServerError.capacityReached }
        let token = UUID().uuidString.lowercased()
        invites[token] = Invite(roomID: roomID, playerID: playerID, expiresAt: now.addingTimeInterval(configuration.inviteLifetime))
        return token
    }

    public func join(roomID: UUID, playerID: UUID, invite token: String? = nil, now: Date = Date()) throws -> GameRoomSnapshot {
        let reconnectGraceExpired = rooms[roomID]?.disconnectedUntil[playerID].map { $0 <= now } ?? false
        removeExpiredMembers(in: roomID, now: now)
        guard !reconnectGraceExpired else { throw GameServerError.roomNotFoundOrUnauthorized }
        guard var room = rooms[roomID] else { throw GameServerError.roomNotFoundOrUnauthorized }
        if room.members.contains(playerID) {
            if let reconnectDeadline = room.disconnectedUntil[playerID] {
                guard reconnectDeadline > now else {
                    try leave(roomID: roomID, playerID: playerID)
                    throw GameServerError.roomNotFoundOrUnauthorized
                }
                room.disconnectedUntil.removeValue(forKey: playerID)
                room.revision &+= 1
                rooms[roomID] = room
            }
            return snapshot(roomID, room)
        }
        var inviteToConsume: String?
        if room.visibility == .private {
            guard let token, let invite = invites[token], invite.roomID == roomID,
                  invite.playerID == playerID, invite.expiresAt > now else { throw GameServerError.roomNotFoundOrUnauthorized }
            inviteToConsume = token
        }
        guard room.members.count < configuration.maximumMembersPerRoom else { throw GameServerError.roomFull }
        if let inviteToConsume { invites.removeValue(forKey: inviteToConsume) }
        room.members.insert(playerID); room.disconnectedUntil.removeValue(forKey: playerID); room.revision &+= 1
        rooms[roomID] = room
        return snapshot(roomID, room)
    }

    public func disconnect(roomID: UUID, playerID: UUID, now: Date = Date()) throws {
        guard var room = rooms[roomID], room.members.contains(playerID) else { throw GameServerError.roomNotFoundOrUnauthorized }
        if configuration.reconnectGracePeriod == 0 { try leave(roomID: roomID, playerID: playerID); return }
        // Duplicate disconnect signals must not keep extending the reconnect window.
        guard room.disconnectedUntil[playerID] == nil else { return }
        room.disconnectedUntil[playerID] = now.addingTimeInterval(configuration.reconnectGracePeriod)
        room.revision &+= 1; rooms[roomID] = room
    }

    public func leave(roomID: UUID, playerID: UUID) throws {
        guard var room = rooms[roomID], room.members.remove(playerID) != nil else { throw GameServerError.roomNotFoundOrUnauthorized }
        room.disconnectedUntil.removeValue(forKey: playerID)
        if room.members.isEmpty {
            rooms.removeValue(forKey: roomID)
            publicRoomOrder.removeAll { $0 == roomID }
            invites = invites.filter { $0.value.roomID != roomID }
            return
        }
        if room.ownerID == playerID { room.ownerID = room.members.sorted(by: { $0.uuidString < $1.uuidString }).first! }
        room.revision &+= 1; rooms[roomID] = room
    }

    /// Removes expired disconnected members and returns the count removed.
    @discardableResult public func reapExpired(now: Date = Date()) -> Int {
        let expired = rooms.flatMap { id, room in
            room.disconnectedUntil.compactMap { player, deadline in deadline <= now ? (id, player) : nil }
        }
        var removed = 0
        for (roomID, playerID) in expired where rooms[roomID]?.members.contains(playerID) == true {
            try? leave(roomID: roomID, playerID: playerID); removed += 1
        }
        invites = invites.filter { $0.value.expiresAt > now }
        return removed
    }

    public func room(id: UUID, now: Date = Date()) -> GameRoomSnapshot? {
        removeExpiredMembers(in: roomIDs, now: now)
        return rooms[id].map { snapshot(id, $0) }
    }
    /// Lists only public rooms in creation order. The result is paged and excludes member IDs.
    public func publicRooms(offset: Int = 0, limit: Int = 100, now: Date = Date()) -> (total: Int, rooms: [GameRoomListing]) {
        removeExpiredMembers(in: roomIDs, now: now)
        invites = invites.filter { $0.value.expiresAt > now }
        let boundedOffset = max(0, offset)
        let boundedLimit = min(100, max(1, limit))
        let total = publicRoomOrder.count
        guard boundedOffset < total else { return (total, []) }
        let end = min(total, boundedOffset + boundedLimit)
        let page = publicRoomOrder[boundedOffset..<end].compactMap { id -> GameRoomListing? in
            guard let room = rooms[id] else { return nil }
            return GameRoomListing(id: id, memberCount: room.members.count,
                                   maximumMembers: configuration.maximumMembersPerRoom, revision: room.revision)
        }
        return (total, page)
    }
    public var roomCount: Int {
        removeExpiredMembers(in: roomIDs, now: Date())
        return rooms.count
    }
    private var roomIDs: [UUID] { Array(rooms.keys) }
    private func snapshot(_ id: UUID, _ room: Room) -> GameRoomSnapshot {
        GameRoomSnapshot(id: id, ownerID: room.ownerID, visibility: room.visibility, members: room.members, disconnectedUntil: room.disconnectedUntil, revision: room.revision)
    }

    /// Expiry is enforced on room mutations as well as by the optional reaper, so
    /// delayed maintenance cannot leave stale members occupying capacity.
    private func removeExpiredMembers(in roomID: UUID, now: Date) {
        guard let room = rooms[roomID] else { return }
        let expired = room.disconnectedUntil.compactMap { playerID, deadline in
            deadline <= now ? playerID : nil
        }
        for playerID in expired {
            try? leave(roomID: roomID, playerID: playerID)
        }
    }

    private func removeExpiredMembers(in roomIDs: [UUID], now: Date) {
        for roomID in roomIDs {
            removeExpiredMembers(in: roomID, now: now)
        }
    }
}

// MARK: - Deterministic, idempotent turn-based commands

public struct GameStateEvent: Sendable, Equatable, Codable {
    public let sequence: UInt64
    public let commandID: UUID
    public let playerID: UUID
    public let payload: Data
    public let state: Data
    public init(sequence: UInt64, commandID: UUID, playerID: UUID, payload: Data, state: Data) {
        self.sequence = sequence; self.commandID = commandID; self.playerID = playerID; self.payload = payload; self.state = state
    }
}

public struct GameStateCheckpoint: Sendable, Equatable, Codable {
    public let revision: UInt64
    public let state: Data
    public let events: [GameStateEvent]
    public init(revision: UInt64, state: Data, events: [GameStateEvent]) {
        self.revision = revision; self.state = state; self.events = events
    }
}

public enum GameCommandResult: Sendable, Equatable {
    case applied(GameStateEvent)
    case duplicate(GameStateEvent)
}

/// Server-side reducer boundary for point-and-click/turn-based games. Reducers validate
/// game rules and return the next canonical state; clients submit intent, never state.
public actor GameCommandProcessor {
    public typealias Reducer = @Sendable (_ currentState: Data, _ playerID: UUID, _ command: Data) throws -> Data
    private let maximumEvents: Int
    private let maximumStateBytes: Int
    private let maximumHistoryBytes: Int
    private let maximumCommandBytes: Int
    private var historyBytes = 0
    private var state: Data
    private var revision: UInt64 = 0
    private var events: [GameStateEvent] = []
    private var processed: [UUID: GameStateEvent] = [:]

    public init(initialState: Data, maximumEvents: Int = 10_000, maximumStateBytes: Int = 1_048_576,
                maximumHistoryBytes: Int = 67_108_864, maximumCommandBytes: Int = 65_536) throws {
        guard (1...1_000_000).contains(maximumEvents), (1...16_777_216).contains(maximumStateBytes),
              (1...1_073_741_824).contains(maximumHistoryBytes), (1...1_048_576).contains(maximumCommandBytes),
              initialState.count <= maximumStateBytes else { throw GameServerError.invalidConfiguration }
        self.state = initialState; self.maximumEvents = maximumEvents; self.maximumStateBytes = maximumStateBytes
        self.maximumHistoryBytes = maximumHistoryBytes; self.maximumCommandBytes = maximumCommandBytes
    }

    /// Rehydrates a complete command history at startup and verifies every event by
    /// replaying it through the same deterministic reducer used for live commands.
    /// Checkpoints produced by `checkpoint()` contain the complete sequence from 1.
    public init(
        replaying checkpoint: GameStateCheckpoint,
        from initialState: Data,
        maximumEvents: Int = 10_000,
        maximumStateBytes: Int = 1_048_576,
        maximumHistoryBytes: Int = 67_108_864,
        maximumCommandBytes: Int = 65_536,
        reducer: Reducer
    ) throws {
        guard (1...1_000_000).contains(maximumEvents), (1...16_777_216).contains(maximumStateBytes),
              (1...1_073_741_824).contains(maximumHistoryBytes), (1...1_048_576).contains(maximumCommandBytes),
              initialState.count <= maximumStateBytes, checkpoint.state.count <= maximumStateBytes,
              checkpoint.events.count <= maximumEvents,
              checkpoint.revision == UInt64(checkpoint.events.count) else { throw GameServerError.invalidCheckpoint }

        var replayedState = initialState
        var historyBytes = 0
        var seenCommandIDs = Set<UUID>()
        for (index, event) in checkpoint.events.enumerated() {
            guard event.sequence == UInt64(index) &+ 1,
                  event.payload.count <= maximumCommandBytes,
                  event.state.count <= maximumStateBytes,
                  seenCommandIDs.insert(event.commandID).inserted,
                  event.payload.count <= maximumHistoryBytes,
                  event.state.count <= maximumHistoryBytes - event.payload.count,
                  historyBytes <= maximumHistoryBytes - event.payload.count - event.state.count else {
                throw GameServerError.invalidCheckpoint
            }
            let nextState = try reducer(replayedState, event.playerID, event.payload)
            guard nextState.count <= maximumStateBytes, nextState == event.state else {
                throw GameServerError.invalidCheckpoint
            }
            replayedState = nextState
            historyBytes += event.payload.count + event.state.count
        }
        guard replayedState == checkpoint.state else { throw GameServerError.invalidCheckpoint }

        self.state = checkpoint.state
        self.revision = checkpoint.revision
        self.maximumEvents = maximumEvents
        self.maximumStateBytes = maximumStateBytes
        self.maximumHistoryBytes = maximumHistoryBytes
        self.maximumCommandBytes = maximumCommandBytes
        self.historyBytes = historyBytes
        self.events = checkpoint.events
        self.processed = Dictionary(uniqueKeysWithValues: checkpoint.events.map { ($0.commandID, $0) })
    }

    public func submit(commandID: UUID, playerID: UUID, command: Data, expectedRevision: UInt64? = nil, reducer: Reducer) throws -> GameCommandResult {
        if let previous = processed[commandID] {
            guard previous.playerID == playerID, previous.payload == command else {
                throw GameServerError.commandIDConflict
            }
            return .duplicate(previous)
        }
        if let expectedRevision, expectedRevision != revision { throw GameServerError.revisionConflict(current: revision) }
        guard events.count < maximumEvents else { throw GameServerError.capacityReached }
        guard command.count <= maximumCommandBytes else { throw GameServerError.stateTooLarge }
        let next = try reducer(state, playerID, command)
        guard next.count <= maximumStateBytes else { throw GameServerError.stateTooLarge }
        guard command.count <= maximumHistoryBytes, next.count <= maximumHistoryBytes - command.count,
              historyBytes <= maximumHistoryBytes - command.count - next.count else { throw GameServerError.historyCapacityReached }
        let event = GameStateEvent(sequence: revision &+ 1, commandID: commandID, playerID: playerID, payload: command, state: next)
        state = next; revision = event.sequence; events.append(event); processed[commandID] = event
        historyBytes += command.count + next.count
        return .applied(event)
    }

    public func checkpoint() -> GameStateCheckpoint { GameStateCheckpoint(revision: revision, state: state, events: events) }
    public func events(after sequence: UInt64) -> [GameStateEvent] { events.filter { $0.sequence > sequence } }
    public var currentRevision: UInt64 { revision }
}

// MARK: - In-process matchmaking queue

public struct GameMatchmakingConfiguration: Sendable, Equatable {
    public let minimumPlayers: Int
    public let maximumPlayers: Int
    public let maximumQueueEntries: Int
    public let maximumQueuedPlayers: Int
    public let initialSkillWindow: Int
    public let skillWindowExpansion: Int
    public let expansionInterval: TimeInterval
    public static let standard = GameMatchmakingConfiguration(minimumPlayers: 2, maximumPlayers: 4, maximumQueueEntries: 10_000, maximumQueuedPlayers: 50_000, initialSkillWindow: 100, skillWindowExpansion: 100, expansionInterval: 10, standard: ())
    public init(minimumPlayers: Int = 2, maximumPlayers: Int = 4, maximumQueueEntries: Int = 10_000,
                maximumQueuedPlayers: Int = 50_000,
                initialSkillWindow: Int = 100, skillWindowExpansion: Int = 100, expansionInterval: TimeInterval = 10) throws {
        guard (1...1_000).contains(minimumPlayers), maximumPlayers >= minimumPlayers, maximumPlayers <= 10_000,
              (1...1_000_000).contains(maximumQueueEntries), (1...10_000_000).contains(maximumQueuedPlayers),
              (0...1_000_000).contains(initialSkillWindow),
              (1...1_000_000).contains(skillWindowExpansion), expansionInterval.isFinite, (0.01...86_400).contains(expansionInterval) else {
            throw GameServerError.invalidConfiguration
        }
        self.minimumPlayers = minimumPlayers; self.maximumPlayers = maximumPlayers
        self.maximumQueueEntries = maximumQueueEntries; self.maximumQueuedPlayers = maximumQueuedPlayers; self.initialSkillWindow = initialSkillWindow
        self.skillWindowExpansion = skillWindowExpansion; self.expansionInterval = expansionInterval
    }
    private init(minimumPlayers: Int, maximumPlayers: Int, maximumQueueEntries: Int, maximumQueuedPlayers: Int, initialSkillWindow: Int, skillWindowExpansion: Int, expansionInterval: TimeInterval, standard: Void) {
        self.minimumPlayers = minimumPlayers; self.maximumPlayers = maximumPlayers
        self.maximumQueueEntries = maximumQueueEntries; self.maximumQueuedPlayers = maximumQueuedPlayers; self.initialSkillWindow = initialSkillWindow
        self.skillWindowExpansion = skillWindowExpansion; self.expansionInterval = expansionInterval
    }
}

public struct GameMatchTicket: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let partyID: UUID
    public let playerIDs: [UUID]
    public let mode: String
    public let region: String
    public let skill: Int
    public let enqueuedAt: Date
    public init(id: UUID = UUID(), partyID: UUID = UUID(), playerIDs: [UUID], mode: String, region: String, skill: Int, enqueuedAt: Date = Date()) {
        self.id = id; self.partyID = partyID; self.playerIDs = playerIDs; self.mode = mode; self.region = region; self.skill = skill; self.enqueuedAt = enqueuedAt
    }
}

public struct GameMatchAssignment: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let ticketIDs: [UUID]
    public let playerIDs: [UUID]
    public let mode: String
    public let region: String
}

public struct GameMatchmakingPlan: Sendable, Equatable {
    public let assignments: [GameMatchAssignment]
    public let waitingTickets: [GameMatchTicket]
}

/// Shared deterministic matching policy used by local and distributed queue stores.
public enum GameMatchmakingPlanner {
    public static func plan(
        tickets: [GameMatchTicket],
        configuration: GameMatchmakingConfiguration,
        now: Date = Date()
    ) -> GameMatchmakingPlan {
        var queue = tickets
        var assignments: [GameMatchAssignment] = []
        while !queue.isEmpty {
            var plan: (seed: GameMatchTicket, selected: [GameMatchTicket])?
            for seed in queue {
                let elapsed = max(0, now.timeIntervalSince(seed.enqueuedAt) / configuration.expansionInterval)
                let expansion = elapsed.isFinite ? Int(min(elapsed, 10_000)) : 10_000
                let window = configuration.initialSkillWindow + expansion * configuration.skillWindowExpansion
                var selected: [GameMatchTicket] = []
                var playerCount = 0
                for ticket in queue where ticket.mode == seed.mode && ticket.region == seed.region && abs(ticket.skill - seed.skill) <= window {
                    guard playerCount + ticket.playerIDs.count <= configuration.maximumPlayers else { continue }
                    selected.append(ticket); playerCount += ticket.playerIDs.count
                    if playerCount >= configuration.maximumPlayers { break }
                }
                if playerCount >= configuration.minimumPlayers { plan = (seed, selected); break }
            }
            guard let plan else { break }
            let selectedIDs = Set(plan.selected.map(\.id))
            queue.removeAll { selectedIDs.contains($0.id) }
            let players = plan.selected.flatMap(\.playerIDs)
            assignments.append(GameMatchAssignment(
                id: UUID(),
                ticketIDs: plan.selected.map(\.id),
                playerIDs: players,
                mode: plan.seed.mode,
                region: plan.seed.region
            ))
        }
        return GameMatchmakingPlan(assignments: assignments, waitingTickets: queue)
    }
}

/// Single-process fair queue. A multi-replica deployment needs an atomic distributed claim store.
public actor GameMatchmakingQueue {
    private let configuration: GameMatchmakingConfiguration
    private var queue: [GameMatchTicket] = []
    private var playerTickets: [UUID: UUID] = [:]
    private var queuedPlayers = 0
    public init(configuration: GameMatchmakingConfiguration = .standard) { self.configuration = configuration }
    public func enqueue(_ ticket: GameMatchTicket) throws {
        guard !ticket.playerIDs.isEmpty, ticket.playerIDs.count <= configuration.maximumPlayers,
              !ticket.mode.isEmpty, ticket.mode.utf8.count <= 64, !ticket.region.isEmpty, ticket.region.utf8.count <= 64,
              ticket.skill >= 0, ticket.skill <= 1_000_000_000,
              Set(ticket.playerIDs).count == ticket.playerIDs.count,
              !queue.contains(where: { $0.id == ticket.id || $0.partyID == ticket.partyID }) else { throw GameServerError.invalidMatchTicket }
        guard queue.count < configuration.maximumQueueEntries,
              queuedPlayers <= configuration.maximumQueuedPlayers - ticket.playerIDs.count else { throw GameServerError.capacityReached }
        guard ticket.playerIDs.allSatisfy({ playerTickets[$0] == nil }) else { throw GameServerError.playerAlreadyQueued }
        queue.append(ticket); queuedPlayers += ticket.playerIDs.count; ticket.playerIDs.forEach { playerTickets[$0] = ticket.id }
    }
    @discardableResult public func cancel(ticketID: UUID) -> Bool {
        guard let index = queue.firstIndex(where: { $0.id == ticketID }) else { return false }
        let ticket = queue.remove(at: index); queuedPlayers -= ticket.playerIDs.count; ticket.playerIDs.forEach { playerTickets.removeValue(forKey: $0) }; return true
    }
    public func findMatches(now: Date = Date()) -> [GameMatchAssignment] {
        let plan = GameMatchmakingPlanner.plan(tickets: queue, configuration: configuration, now: now)
        queue = plan.waitingTickets
        queuedPlayers = queue.reduce(0) { $0 + $1.playerIDs.count }
        playerTickets = Dictionary(uniqueKeysWithValues: queue.flatMap { ticket in ticket.playerIDs.map { ($0, ticket.id) } })
        return plan.assignments
    }
    public var queuedEntryCount: Int { queue.count }
    public var queuedPlayerCount: Int { queuedPlayers }
}

// MARK: - Co-op session/mission state

public enum GameCoopPhase: String, Sendable, Codable { case lobby, active, extracted, failed, closed }

/// Opaque server-authored NPC action scheduled against the session simulation tick.
public struct GameCoopScheduledNPCAction: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let npcID: String
    public let dueTick: UInt64
    public let payload: Data

    public init(id: UUID = UUID(), npcID: String, dueTick: UInt64, payload: Data) {
        self.id = id
        self.npcID = npcID
        self.dueTick = dueTick
        self.payload = payload
    }
}

/// Bounded work returned to the authoritative game loop for one scheduler poll.
public struct GameCoopNPCActionBatch: Sendable, Equatable {
    public let tick: UInt64
    public let actions: [GameCoopScheduledNPCAction]
}

/// Encoded server-owned session state paired with its authoritative revision for recovery adapters.
public struct GameCoopSessionRecoveryCheckpoint: Sendable, Equatable {
    public let sessionRevision: UInt64
    public let data: Data
}

public struct GameCoopSnapshot: Sendable, Equatable {
    public let sessionID: UUID
    public let phase: GameCoopPhase
    public let revision: UInt64
    public let completedObjectives: Set<String>
    public let objectiveProgress: [String: UInt64]
    public let deterministicDrawCount: UInt64
    public let publicState: Data
    public let privatePlayerState: [UUID: Data]
}

/// Session mission state machine with idempotent objective completion and per-player state.
public actor GameCoopSession {
    private struct ProcessedCommand: Codable, Equatable, Sendable {
        let playerID: UUID
        let objectiveID: String
        let progressDelta: UInt64?
        let publicStateDigest: Data
        let privateStateDigest: Data?
    }

    private struct RecoveryEnvelope: Codable, Sendable {
        let schemaVersion: UInt16
        let sessionID: UUID
        let maximumPlayers: Int
        let maximumObjectives: Int
        let maximumStateBytes: Int
        let maximumProcessedCommands: Int
        let maximumQueuedNPCActions: Int
        let maximumNPCActionBytes: Int
        let maximumQueuedNPCActionBytes: Int
        let maximumNPCActionsPerBatch: Int
        let maximumProcessedNPCActions: Int
        let phase: GameCoopPhase
        let members: Set<UUID>
        let objectives: Set<String>
        let objectivePrerequisites: [String: Set<String>]
        let objectiveProgressTargets: [String: UInt64]
        let completed: Set<String>
        let progress: [String: UInt64]
        let processedCommands: [UUID: ProcessedCommand]
        let publicState: Data
        let privateState: [UUID: Data]
        let disconnectedUntil: [UUID: Date]?
        let abandonedMembers: Set<UUID>?
        let revision: UInt64
        let deterministicSeed: UInt64?
        let deterministicDrawCount: UInt64
        let simulationTick: UInt64
        let scheduledNPCActions: [UUID: GameCoopScheduledNPCAction]
        let pendingNPCDispatches: [UUID: GameCoopScheduledNPCAction]?
        let seenNPCActionIDs: Set<UUID>

        /// Sets are encoded in stable order so reducer replay produces identical
        /// checkpoint bytes across process launches with different hash seeds.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(maximumPlayers, forKey: .maximumPlayers)
            try container.encode(maximumObjectives, forKey: .maximumObjectives)
            try container.encode(maximumStateBytes, forKey: .maximumStateBytes)
            try container.encode(maximumProcessedCommands, forKey: .maximumProcessedCommands)
            try container.encode(maximumQueuedNPCActions, forKey: .maximumQueuedNPCActions)
            try container.encode(maximumNPCActionBytes, forKey: .maximumNPCActionBytes)
            try container.encode(maximumQueuedNPCActionBytes, forKey: .maximumQueuedNPCActionBytes)
            try container.encode(maximumNPCActionsPerBatch, forKey: .maximumNPCActionsPerBatch)
            try container.encode(maximumProcessedNPCActions, forKey: .maximumProcessedNPCActions)
            try container.encode(phase, forKey: .phase)
            try container.encode(members.sorted { $0.uuidString < $1.uuidString }, forKey: .members)
            try container.encode(objectives.sorted(), forKey: .objectives)
            try container.encode(objectivePrerequisites.mapValues { $0.sorted() }, forKey: .objectivePrerequisites)
            try container.encode(objectiveProgressTargets, forKey: .objectiveProgressTargets)
            try container.encode(completed.sorted(), forKey: .completed)
            try container.encode(progress, forKey: .progress)
            try container.encode(processedCommands, forKey: .processedCommands)
            try container.encode(publicState, forKey: .publicState)
            try container.encode(privateState, forKey: .privateState)
            try container.encodeIfPresent(disconnectedUntil, forKey: .disconnectedUntil)
            try container.encodeIfPresent(abandonedMembers?.sorted { $0.uuidString < $1.uuidString }, forKey: .abandonedMembers)
            try container.encode(revision, forKey: .revision)
            try container.encodeIfPresent(deterministicSeed, forKey: .deterministicSeed)
            try container.encode(deterministicDrawCount, forKey: .deterministicDrawCount)
            try container.encode(simulationTick, forKey: .simulationTick)
            try container.encode(scheduledNPCActions, forKey: .scheduledNPCActions)
            try container.encodeIfPresent(pendingNPCDispatches, forKey: .pendingNPCDispatches)
            try container.encode(seenNPCActionIDs.sorted { $0.uuidString < $1.uuidString }, forKey: .seenNPCActionIDs)
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, sessionID, maximumPlayers, maximumObjectives, maximumStateBytes
            case maximumProcessedCommands, maximumQueuedNPCActions, maximumNPCActionBytes
            case maximumQueuedNPCActionBytes, maximumNPCActionsPerBatch, maximumProcessedNPCActions
            case phase, members, objectives, objectivePrerequisites, objectiveProgressTargets
            case completed, progress, processedCommands, publicState, privateState, disconnectedUntil
            case abandonedMembers, revision, deterministicSeed, deterministicDrawCount, simulationTick
            case scheduledNPCActions, pendingNPCDispatches, seenNPCActionIDs
        }
    }

    private let maximumPlayers: Int
    private let maximumObjectives: Int
    private let maximumStateBytes: Int
    private let maximumProcessedCommands: Int
    private let maximumQueuedNPCActions: Int
    private let maximumNPCActionBytes: Int
    private let maximumQueuedNPCActionBytes: Int
    private let maximumNPCActionsPerBatch: Int
    private let maximumProcessedNPCActions: Int
    private var phase: GameCoopPhase = .lobby
    private var members: Set<UUID> = []
    private var disconnectedUntil: [UUID: Date] = [:]
    private var abandonedMembers: Set<UUID> = []
    private var objectives: Set<String> = []
    private let objectivePrerequisites: [String: Set<String>]
    private let objectiveProgressTargets: [String: UInt64]
    private var completed: Set<String> = []
    private var progress: [String: UInt64] = [:]
    private var processedCommands: [UUID: ProcessedCommand] = [:]
    private var publicState = Data()
    private var privateState: [UUID: Data] = [:]
    private var privateStateBytes = 0
    private var revision: UInt64 = 0
    private let deterministicSeed: UInt64?
    private var deterministicDrawCount: UInt64 = 0
    private var simulationTick: UInt64 = 0
    private var scheduledNPCActions: [UUID: GameCoopScheduledNPCAction] = [:]
    private var pendingNPCDispatches: [UUID: GameCoopScheduledNPCAction] = [:]
    private var seenNPCActionIDs: Set<UUID> = []
    private var scheduledNPCActionBytes = 0
    private var pendingNPCDispatchBytes = 0
    public let sessionID: UUID

    public init(sessionID: UUID = UUID(), maximumPlayers: Int = 4, objectives: Set<String>, maximumObjectives: Int = 256,
                maximumStateBytes: Int = 1_048_576, maximumProcessedCommands: Int = 10_000,
                objectivePrerequisites: [String: Set<String>] = [:], objectiveProgressTargets: [String: UInt64] = [:],
                deterministicSeed: UInt64? = nil, maximumQueuedNPCActions: Int = 1_024,
                maximumNPCActionBytes: Int = 16_384, maximumQueuedNPCActionBytes: Int = 1_048_576,
                maximumNPCActionsPerBatch: Int = 64, maximumProcessedNPCActions: Int = 10_000) throws {
        let dependencyCount = objectivePrerequisites.values.reduce(0) { $0 + $1.count }
        guard (1...256).contains(maximumPlayers), (1...4_096).contains(maximumObjectives), objectives.count <= maximumObjectives,
              objectives.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              dependencyCount <= 16_384,
              objectivePrerequisites.allSatisfy({ objectives.contains($0.key) && $0.value.isSubset(of: objectives) && !$0.value.contains($0.key) }),
              objectiveProgressTargets.count <= objectives.count,
              objectiveProgressTargets.allSatisfy({ objectives.contains($0.key) && $0.value > 0 }),
              (1...100_000).contains(maximumQueuedNPCActions),
              (1...1_048_576).contains(maximumNPCActionBytes),
              (maximumNPCActionBytes...16_777_216).contains(maximumQueuedNPCActionBytes),
              (1...min(4_096, maximumQueuedNPCActions)).contains(maximumNPCActionsPerBatch),
              (1...100_000).contains(maximumProcessedNPCActions),
              (1...16_777_216).contains(maximumStateBytes), (1...100_000).contains(maximumProcessedCommands) else {
            throw GameServerError.invalidConfiguration
        }
        var visiting = Set<String>()
        var visited = Set<String>()
        func hasCycle(_ objective: String) -> Bool {
            if visiting.contains(objective) { return true }
            if visited.contains(objective) { return false }
            visiting.insert(objective)
            for prerequisite in objectivePrerequisites[objective, default: []] where hasCycle(prerequisite) { return true }
            visiting.remove(objective)
            visited.insert(objective)
            return false
        }
        guard !objectives.contains(where: hasCycle) else { throw GameServerError.invalidConfiguration }
        self.sessionID = sessionID; self.maximumPlayers = maximumPlayers; self.maximumObjectives = maximumObjectives
        self.maximumStateBytes = maximumStateBytes; self.maximumProcessedCommands = maximumProcessedCommands
        self.objectives = objectives
        self.objectivePrerequisites = objectivePrerequisites
        self.objectiveProgressTargets = objectiveProgressTargets
        self.deterministicSeed = deterministicSeed
        self.maximumQueuedNPCActions = maximumQueuedNPCActions
        self.maximumNPCActionBytes = maximumNPCActionBytes
        self.maximumQueuedNPCActionBytes = maximumQueuedNPCActionBytes
        self.maximumNPCActionsPerBatch = maximumNPCActionsPerBatch
        self.maximumProcessedNPCActions = maximumProcessedNPCActions
    }

    /// Restores trusted server-owned state. Rejects oversized, malformed or internally inconsistent checkpoints.
    public init(restoringCheckpoint data: Data, maximumCheckpointBytes: Int = 16_777_216) throws {
        guard (1...67_108_864).contains(maximumCheckpointBytes), data.count <= maximumCheckpointBytes else {
            throw GameServerError.invalidCheckpoint
        }
        let envelope: RecoveryEnvelope
        do { envelope = try JSONDecoder().decode(RecoveryEnvelope.self, from: data) }
        catch { throw GameServerError.invalidCheckpoint }

        let members = envelope.members
        let objectives = envelope.objectives
        let completed = envelope.completed
        let disconnectedUntil = envelope.disconnectedUntil ?? [:]
        let abandonedMembers = envelope.abandonedMembers ?? []
        let pendingNPCDispatches = envelope.pendingNPCDispatches ?? [:]
        let seenActionIDs = envelope.seenNPCActionIDs
        let dependenciesAreValid = envelope.objectivePrerequisites.allSatisfy { key, values in
            objectives.contains(key) && values.isSubset(of: objectives)
        }
        let prerequisites = envelope.objectivePrerequisites
        let dependencyCount = prerequisites.values.reduce(0) { $0 + $1.count }
        guard envelope.schemaVersion == 1,
              (1...256).contains(envelope.maximumPlayers),
              members.count <= envelope.maximumPlayers,
              disconnectedUntil.keys.allSatisfy(members.contains),
              abandonedMembers.isSubset(of: members),
              abandonedMembers.isDisjoint(with: disconnectedUntil.keys),
              (1...4_096).contains(envelope.maximumObjectives),
              objectives.count <= envelope.maximumObjectives,
              objectives.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              dependenciesAreValid, dependencyCount <= 16_384,
              prerequisites.allSatisfy({ !$0.value.contains($0.key) }),
              envelope.objectiveProgressTargets.count <= objectives.count,
              envelope.objectiveProgressTargets.allSatisfy({ objectives.contains($0.key) && $0.value > 0 }),
              completed.isSubset(of: objectives),
              envelope.progress.allSatisfy({ entry in
                  guard let target = envelope.objectiveProgressTargets[entry.key] else { return false }
                  return objectives.contains(entry.key) && entry.value > 0 && entry.value <= target
              }),
              envelope.progress.keys.allSatisfy({ envelope.objectiveProgressTargets[$0] != nil }),
              completed.allSatisfy({ prerequisites[$0, default: []].isSubset(of: completed) }),
              completed.allSatisfy({ objective in
                  envelope.objectiveProgressTargets[objective].map { envelope.progress[objective] == $0 } ?? true
              }),
              (1...16_777_216).contains(envelope.maximumStateBytes),
              (1...100_000).contains(envelope.maximumProcessedCommands),
              envelope.processedCommands.count <= envelope.maximumProcessedCommands,
              envelope.processedCommands.values.allSatisfy({ command in
                  members.contains(command.playerID) && objectives.contains(command.objectiveID)
                      && command.publicStateDigest.count == 32
                      && (command.privateStateDigest == nil || command.privateStateDigest?.count == 32)
                      && (command.progressDelta.map { $0 > 0 && envelope.objectiveProgressTargets[command.objectiveID] != nil } ?? true)
              }),
              envelope.publicState.count <= envelope.maximumStateBytes,
              envelope.privateState.keys.allSatisfy(members.contains),
              envelope.privateState.keys.allSatisfy({ !abandonedMembers.contains($0) }),
              envelope.privateState.values.allSatisfy({ $0.count <= envelope.maximumStateBytes }),
              envelope.privateState.values.reduce(envelope.publicState.count, { $0 + $1.count }) <= envelope.maximumStateBytes,
              (1...100_000).contains(envelope.maximumQueuedNPCActions),
              (1...1_048_576).contains(envelope.maximumNPCActionBytes),
              (envelope.maximumNPCActionBytes...16_777_216).contains(envelope.maximumQueuedNPCActionBytes),
              (1...min(4_096, envelope.maximumQueuedNPCActions)).contains(envelope.maximumNPCActionsPerBatch),
              (1...100_000).contains(envelope.maximumProcessedNPCActions),
              envelope.scheduledNPCActions.count <= envelope.maximumQueuedNPCActions,
              pendingNPCDispatches.count <= envelope.maximumQueuedNPCActions,
              envelope.scheduledNPCActions.count + pendingNPCDispatches.count <= envelope.maximumQueuedNPCActions,
              seenActionIDs.count <= envelope.maximumProcessedNPCActions,
              Set(envelope.scheduledNPCActions.keys).isDisjoint(with: pendingNPCDispatches.keys),
              envelope.scheduledNPCActions.allSatisfy({ entry in
                  entry.key == entry.value.id && seenActionIDs.contains(entry.value.id)
                      && !entry.value.npcID.isEmpty && entry.value.npcID.utf8.count <= 128
                      && entry.value.dueTick > envelope.simulationTick && entry.value.payload.count <= envelope.maximumNPCActionBytes
              }),
              pendingNPCDispatches.allSatisfy({ entry in
                  entry.key == entry.value.id && seenActionIDs.contains(entry.value.id)
                      && !entry.value.npcID.isEmpty && entry.value.npcID.utf8.count <= 128
                      && entry.value.dueTick <= envelope.simulationTick && entry.value.payload.count <= envelope.maximumNPCActionBytes
              }),
              envelope.scheduledNPCActions.values.reduce(0, { $0 + $1.payload.count })
                  + pendingNPCDispatches.values.reduce(0, { $0 + $1.payload.count }) <= envelope.maximumQueuedNPCActionBytes,
              (envelope.scheduledNPCActions.isEmpty && pendingNPCDispatches.isEmpty || envelope.phase == .active),
              (envelope.deterministicSeed != nil || envelope.deterministicDrawCount == 0),
              (envelope.phase == .lobby || !members.isEmpty) else {
            throw GameServerError.invalidCheckpoint
        }
        var visiting = Set<String>()
        var visited = Set<String>()
        func hasCycle(_ objective: String) -> Bool {
            if visiting.contains(objective) { return true }
            if visited.contains(objective) { return false }
            visiting.insert(objective)
            for prerequisite in prerequisites[objective, default: []] where hasCycle(prerequisite) { return true }
            visiting.remove(objective)
            visited.insert(objective)
            return false
        }
        guard !objectives.contains(where: hasCycle) else { throw GameServerError.invalidCheckpoint }

        self.sessionID = envelope.sessionID
        self.maximumPlayers = envelope.maximumPlayers
        self.maximumObjectives = envelope.maximumObjectives
        self.maximumStateBytes = envelope.maximumStateBytes
        self.maximumProcessedCommands = envelope.maximumProcessedCommands
        self.maximumQueuedNPCActions = envelope.maximumQueuedNPCActions
        self.maximumNPCActionBytes = envelope.maximumNPCActionBytes
        self.maximumQueuedNPCActionBytes = envelope.maximumQueuedNPCActionBytes
        self.maximumNPCActionsPerBatch = envelope.maximumNPCActionsPerBatch
        self.maximumProcessedNPCActions = envelope.maximumProcessedNPCActions
        self.phase = envelope.phase
        self.members = members
        self.disconnectedUntil = disconnectedUntil
        self.abandonedMembers = abandonedMembers
        self.objectives = objectives
        self.objectivePrerequisites = prerequisites
        self.objectiveProgressTargets = envelope.objectiveProgressTargets
        self.completed = completed
        self.progress = envelope.progress
        self.processedCommands = envelope.processedCommands
        self.publicState = envelope.publicState
        self.privateState = envelope.privateState
        self.privateStateBytes = envelope.privateState.values.reduce(0) { $0 + $1.count }
        self.revision = envelope.revision
        self.deterministicSeed = envelope.deterministicSeed
        self.deterministicDrawCount = envelope.deterministicDrawCount
        self.simulationTick = envelope.simulationTick
        self.scheduledNPCActions = envelope.scheduledNPCActions
        self.pendingNPCDispatches = pendingNPCDispatches
        self.seenNPCActionIDs = seenActionIDs
        self.scheduledNPCActionBytes = envelope.scheduledNPCActions.values.reduce(0) { $0 + $1.payload.count }
        self.pendingNPCDispatchBytes = pendingNPCDispatches.values.reduce(0) { $0 + $1.payload.count }
    }

    /// Encodes all server-owned session state, including private state and the deterministic seed.
    /// Never send this payload to a game client; pass it to a bounded recovery middleware.
    public func recoveryCheckpoint(maximumBytes: Int = 16_777_216) async throws -> GameCoopSessionRecoveryCheckpoint {
        guard (1...67_108_864).contains(maximumBytes) else { throw GameServerError.invalidConfiguration }
        let envelope = RecoveryEnvelope(
            schemaVersion: 1, sessionID: sessionID, maximumPlayers: maximumPlayers,
            maximumObjectives: maximumObjectives, maximumStateBytes: maximumStateBytes,
            maximumProcessedCommands: maximumProcessedCommands, maximumQueuedNPCActions: maximumQueuedNPCActions,
            maximumNPCActionBytes: maximumNPCActionBytes, maximumQueuedNPCActionBytes: maximumQueuedNPCActionBytes,
            maximumNPCActionsPerBatch: maximumNPCActionsPerBatch, maximumProcessedNPCActions: maximumProcessedNPCActions,
            phase: phase, members: members, objectives: objectives,
            objectivePrerequisites: objectivePrerequisites,
            objectiveProgressTargets: objectiveProgressTargets, completed: completed, progress: progress,
            processedCommands: processedCommands, publicState: publicState, privateState: privateState,
            disconnectedUntil: disconnectedUntil, abandonedMembers: abandonedMembers,
            revision: revision, deterministicSeed: deterministicSeed, deterministicDrawCount: deterministicDrawCount,
            simulationTick: simulationTick,
            scheduledNPCActions: scheduledNPCActions, pendingNPCDispatches: pendingNPCDispatches,
            seenNPCActionIDs: seenNPCActionIDs
        )
        let revision = self.revision
        let data = try await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(envelope)
            guard data.count <= maximumBytes else { throw GameServerError.invalidCheckpoint }
            return data
        }.value
        return GameCoopSessionRecoveryCheckpoint(sessionRevision: revision, data: data)
    }

    public func recoveryCheckpointData(maximumBytes: Int = 16_777_216) async throws -> Data {
        try await recoveryCheckpoint(maximumBytes: maximumBytes).data
    }

    public func join(playerID: UUID) throws {
        guard phase == .lobby else { throw GameServerError.invalidCoopTransition }
        guard !abandonedMembers.contains(playerID) else { throw GameServerError.coopMemberAbandoned }
        if members.contains(playerID) { return }
        guard members.count < maximumPlayers else { throw GameServerError.roomFull }
        members.insert(playerID); revision &+= 1
    }
    public func start() throws { guard phase == .lobby, !members.isEmpty else { throw GameServerError.invalidCoopTransition }; phase = .active; revision &+= 1 }

    /// Marks an active co-op member disconnected for a bounded reconnection window.
    /// Repeated disconnect notifications preserve the first deadline instead of extending it.
    @discardableResult
    public func disconnect(playerID: UUID, gracePeriodMilliseconds: Int64, now: Date = Date()) throws -> Date {
        guard phase == .active, members.contains(playerID) else { throw GameServerError.roomNotFoundOrUnauthorized }
        guard !abandonedMembers.contains(playerID) else { throw GameServerError.coopMemberAbandoned }
        guard (1...86_400_000).contains(gracePeriodMilliseconds) else { throw GameServerError.invalidConfiguration }
        if let existingDeadline = disconnectedUntil[playerID] { return existingDeadline }
        let deadline = now.addingTimeInterval(Double(gracePeriodMilliseconds) / 1_000)
        disconnectedUntil[playerID] = deadline
        revision &+= 1
        return deadline
    }

    /// Restores an authenticated member before their original grace deadline.
    public func reconnect(playerID: UUID, now: Date = Date()) throws {
        guard phase == .active, members.contains(playerID) else { throw GameServerError.roomNotFoundOrUnauthorized }
        guard !abandonedMembers.contains(playerID) else { throw GameServerError.coopMemberAbandoned }
        guard let deadline = disconnectedUntil[playerID] else { return }
        guard deadline > now else {
            abandonDisconnectedMember(playerID)
            revision &+= 1
            throw GameServerError.coopReconnectExpired
        }
        disconnectedUntil.removeValue(forKey: playerID)
        revision &+= 1
    }

    /// Permanently abandons a member and removes their private state. The occupied seat
    /// is retained for the lifetime of this session so an abandoned identity cannot rejoin.
    public func abandon(playerID: UUID) throws {
        guard phase == .active, members.contains(playerID) else { throw GameServerError.roomNotFoundOrUnauthorized }
        guard !abandonedMembers.contains(playerID) else { return }
        abandonDisconnectedMember(playerID)
        revision &+= 1
    }

    /// Expires members whose reconnection window elapsed. No background reaper is required
    /// for authorization: reconnect and every member action check connection state directly.
    @discardableResult
    public func expireDisconnectedMembers(now: Date = Date()) -> [UUID] {
        let expired = disconnectedUntil
            .filter { $0.value <= now }
            .keys
            .sorted { $0.uuidString < $1.uuidString }
        guard !expired.isEmpty else { return [] }
        for playerID in expired { abandonDisconnectedMember(playerID) }
        if disconnectedUntil.isEmpty && connectedMemberCount == 0 {
            phase = .failed
            scheduledNPCActions.removeAll(keepingCapacity: false)
            pendingNPCDispatches.removeAll(keepingCapacity: false)
            seenNPCActionIDs.removeAll(keepingCapacity: false)
            scheduledNPCActionBytes = 0
            pendingNPCDispatchBytes = 0
        }
        revision &+= 1
        return expired
    }

    public var connectedMemberCount: Int { members.count - disconnectedUntil.count - abandonedMembers.count }
    public var disconnectedMemberCount: Int { disconnectedUntil.count }

    private func abandonDisconnectedMember(_ playerID: UUID) {
        disconnectedUntil.removeValue(forKey: playerID)
        abandonedMembers.insert(playerID)
        if let removedState = privateState.removeValue(forKey: playerID) {
            privateStateBytes -= removedState.count
        }
        if disconnectedUntil.isEmpty && connectedMemberCount == 0 {
            phase = .failed
            scheduledNPCActions.removeAll(keepingCapacity: false)
            pendingNPCDispatches.removeAll(keepingCapacity: false)
            seenNPCActionIDs.removeAll(keepingCapacity: false)
            scheduledNPCActionBytes = 0
            pendingNPCDispatchBytes = 0
        }
    }
    @discardableResult public func completeObjective(_ objectiveID: String, commandID: UUID, by playerID: UUID, publicState: Data, privatePlayerState: Data? = nil) throws -> Bool {
        guard publicState.count <= maximumStateBytes, (privatePlayerState?.count ?? 0) <= maximumStateBytes else {
            throw GameServerError.stateTooLarge
        }
        let fingerprint = ProcessedCommand(
            playerID: playerID,
            objectiveID: objectiveID,
            progressDelta: nil,
            publicStateDigest: Data(SHA256.hash(data: publicState)),
            privateStateDigest: privatePlayerState.map { Data(SHA256.hash(data: $0)) }
        )
        guard members.contains(playerID) else { throw GameServerError.roomNotFoundOrUnauthorized }
        guard !abandonedMembers.contains(playerID) else { throw GameServerError.coopMemberAbandoned }
        guard disconnectedUntil[playerID] == nil else { throw GameServerError.coopMemberDisconnected }
        if let previous = processedCommands[commandID] {
            guard previous == fingerprint else { throw GameServerError.commandIDConflict }
            return false
        }
        guard phase == .active, objectives.contains(objectiveID) else { throw GameServerError.invalidCoopTransition }
        guard objectivePrerequisites[objectiveID, default: []].isSubset(of: completed) else {
            throw GameServerError.objectivePrerequisitesIncomplete
        }
        guard objectiveProgressTargets[objectiveID].map({ progress[objectiveID, default: 0] >= $0 }) ?? true else {
            throw GameServerError.objectiveProgressIncomplete
        }
        guard processedCommands.count < maximumProcessedCommands else { throw GameServerError.historyCapacityReached }
        let oldPrivateBytes = privateState[playerID]?.count ?? 0
        let retainedOtherStateBytes = privateStateBytes - oldPrivateBytes
        guard publicState.count <= maximumStateBytes - retainedOtherStateBytes else { throw GameServerError.stateTooLarge }
        let nextPrivateBytes = privatePlayerState?.count ?? oldPrivateBytes
        guard nextPrivateBytes <= maximumStateBytes - retainedOtherStateBytes - publicState.count else {
            throw GameServerError.stateTooLarge
        }

        processedCommands[commandID] = fingerprint
        completed.insert(objectiveID); self.publicState = publicState
        if let privatePlayerState { privateState[playerID] = privatePlayerState }
        privateStateBytes = privateStateBytes - oldPrivateBytes + nextPrivateBytes
        revision &+= 1
        return true
    }
    /// Adds bounded, monotonic objective progress. Replaying the same command is a no-op;
    /// reaching the configured target completes the objective in this same actor turn.
    @discardableResult
    public func recordObjectiveProgress(
        _ objectiveID: String,
        by delta: UInt64,
        commandID: UUID,
        playerID: UUID,
        publicState: Data,
        privatePlayerState: Data? = nil
    ) throws -> Bool {
        guard delta > 0, objectiveProgressTargets[objectiveID] != nil else {
            throw GameServerError.invalidObjectiveProgress
        }
        guard publicState.count <= maximumStateBytes, (privatePlayerState?.count ?? 0) <= maximumStateBytes else {
            throw GameServerError.stateTooLarge
        }
        let fingerprint = ProcessedCommand(
            playerID: playerID,
            objectiveID: objectiveID,
            progressDelta: delta,
            publicStateDigest: Data(SHA256.hash(data: publicState)),
            privateStateDigest: privatePlayerState.map { Data(SHA256.hash(data: $0)) }
        )
        guard members.contains(playerID) else { throw GameServerError.roomNotFoundOrUnauthorized }
        guard !abandonedMembers.contains(playerID) else { throw GameServerError.coopMemberAbandoned }
        guard disconnectedUntil[playerID] == nil else { throw GameServerError.coopMemberDisconnected }
        if let previous = processedCommands[commandID] {
            guard previous == fingerprint else { throw GameServerError.commandIDConflict }
            return false
        }
        guard phase == .active, objectives.contains(objectiveID), !completed.contains(objectiveID) else {
            throw GameServerError.invalidCoopTransition
        }
        guard objectivePrerequisites[objectiveID, default: []].isSubset(of: completed) else {
            throw GameServerError.objectivePrerequisitesIncomplete
        }
        guard processedCommands.count < maximumProcessedCommands else { throw GameServerError.historyCapacityReached }

        let oldPrivateBytes = privateState[playerID]?.count ?? 0
        let retainedOtherStateBytes = privateStateBytes - oldPrivateBytes
        guard publicState.count <= maximumStateBytes - retainedOtherStateBytes else { throw GameServerError.stateTooLarge }
        let nextPrivateBytes = privatePlayerState?.count ?? oldPrivateBytes
        guard nextPrivateBytes <= maximumStateBytes - retainedOtherStateBytes - publicState.count else {
            throw GameServerError.stateTooLarge
        }

        let current = progress[objectiveID, default: 0]
        let target = objectiveProgressTargets[objectiveID]!
        let next = delta >= target - current ? target : current + delta
        processedCommands[commandID] = fingerprint
        progress[objectiveID] = next
        if next == target { completed.insert(objectiveID) }
        self.publicState = publicState
        if let privatePlayerState { privateState[playerID] = privatePlayerState }
        privateStateBytes = privateStateBytes - oldPrivateBytes + nextPrivateBytes
        revision &+= 1
        return true
    }
    public func finish(extracted: Bool) throws {
        guard phase == .active else { throw GameServerError.invalidCoopTransition }
        phase = extracted ? .extracted : .failed
        scheduledNPCActions.removeAll(keepingCapacity: false)
        pendingNPCDispatches.removeAll(keepingCapacity: false)
        seenNPCActionIDs.removeAll(keepingCapacity: false)
        scheduledNPCActionBytes = 0
        pendingNPCDispatchBytes = 0
        revision &+= 1
    }
    public func close() throws { guard phase == .extracted || phase == .failed else { throw GameServerError.invalidCoopTransition }; phase = .closed; revision &+= 1 }
    /// Enqueues an action produced by trusted server-side game logic, never by a transport handler directly.
    @discardableResult
    public func scheduleNPCAction(_ action: GameCoopScheduledNPCAction) throws -> Bool {
        guard phase == .active else { throw GameServerError.invalidCoopTransition }
        if let existing = scheduledNPCActions[action.id] {
            guard existing == action else { throw GameServerError.npcActionIDConflict }
            return false
        }
        guard !seenNPCActionIDs.contains(action.id) else { throw GameServerError.npcActionIDConflict }
        guard !action.npcID.isEmpty, action.npcID.utf8.count <= 128,
              action.dueTick > simulationTick, action.payload.count <= maximumNPCActionBytes else {
            throw GameServerError.invalidNPCAction
        }
        guard scheduledNPCActions.count + pendingNPCDispatches.count < maximumQueuedNPCActions,
              action.payload.count <= maximumQueuedNPCActionBytes - scheduledNPCActionBytes - pendingNPCDispatchBytes,
              seenNPCActionIDs.count < maximumProcessedNPCActions else {
            throw GameServerError.npcActionCapacityReached
        }
        scheduledNPCActions[action.id] = action
        seenNPCActionIDs.insert(action.id)
        scheduledNPCActionBytes += action.payload.count
        revision &+= 1
        return true
    }

    /// Advances the session scheduler and removes at most `maximumActions` due actions.
    /// If work exceeds the per-call budget, call again at the same tick to drain the bounded backlog.
    public func advanceNPCSchedule(to tick: UInt64, maximumActions: Int? = nil) throws -> GameCoopNPCActionBatch {
        guard phase == .active, tick >= simulationTick else { throw GameServerError.invalidCoopTransition }
        let limit = maximumActions ?? maximumNPCActionsPerBatch
        guard (1...maximumNPCActionsPerBatch).contains(limit) else { throw GameServerError.invalidConfiguration }
        let advanced = tick != simulationTick
        simulationTick = tick
        let due = scheduledNPCActions.values
            .filter { $0.dueTick <= tick }
            .sorted { lhs, rhs in
                lhs.dueTick == rhs.dueTick ? lhs.id.uuidString < rhs.id.uuidString : lhs.dueTick < rhs.dueTick
            }
            .prefix(limit)
        let actions = Array(due)
        for action in actions {
            scheduledNPCActions.removeValue(forKey: action.id)
            scheduledNPCActionBytes -= action.payload.count
        }
        if !actions.isEmpty || advanced { revision &+= 1 }
        return GameCoopNPCActionBatch(tick: tick, actions: actions)
    }

    /// Moves due server-authored actions into a checkpointed delivery outbox. A recovery
    /// process can read and redeliver them until `acknowledgeNPCActions` is committed.
    /// The caller must durably commit this transition before dispatching its returned batch.
    public func stageNPCActions(to tick: UInt64, maximumActions: Int? = nil) throws -> GameCoopNPCActionBatch {
        guard phase == .active, tick >= simulationTick else { throw GameServerError.invalidCoopTransition }
        let limit = maximumActions ?? maximumNPCActionsPerBatch
        guard (1...maximumNPCActionsPerBatch).contains(limit) else { throw GameServerError.invalidConfiguration }
        let advanced = tick != simulationTick
        simulationTick = tick
        let due = scheduledNPCActions.values
            .filter { $0.dueTick <= tick }
            .sorted { lhs, rhs in
                lhs.dueTick == rhs.dueTick ? lhs.id.uuidString < rhs.id.uuidString : lhs.dueTick < rhs.dueTick
            }
            .prefix(limit)
        let actions = Array(due)
        for action in actions {
            scheduledNPCActions.removeValue(forKey: action.id)
            scheduledNPCActionBytes -= action.payload.count
            pendingNPCDispatches[action.id] = action
            pendingNPCDispatchBytes += action.payload.count
        }
        if !actions.isEmpty || advanced { revision &+= 1 }
        return GameCoopNPCActionBatch(tick: tick, actions: actions)
    }

    /// Returns a stable bounded page of unacknowledged NPC actions without mutating state.
    public func pendingNPCActionBatch(maximumActions: Int? = nil) throws -> GameCoopNPCActionBatch {
        let limit = maximumActions ?? maximumNPCActionsPerBatch
        guard (1...maximumNPCActionsPerBatch).contains(limit) else { throw GameServerError.invalidConfiguration }
        let actions = pendingNPCDispatches.values
            .sorted { lhs, rhs in
                lhs.dueTick == rhs.dueTick ? lhs.id.uuidString < rhs.id.uuidString : lhs.dueTick < rhs.dueTick
            }
            .prefix(limit)
        return GameCoopNPCActionBatch(tick: simulationTick, actions: Array(actions))
    }

    /// Acknowledges actions only after the application has applied them or durably
    /// handed them to an idempotent consumer. Retrying the same outer Redis command ID
    /// is safe; a new command must name only currently pending action IDs.
    @discardableResult
    public func acknowledgeNPCActions(_ actionIDs: [UUID]) throws -> Int {
        guard !actionIDs.isEmpty, actionIDs.count <= maximumNPCActionsPerBatch,
              Set(actionIDs).count == actionIDs.count,
              actionIDs.allSatisfy({ pendingNPCDispatches[$0] != nil }) else {
            throw GameServerError.invalidNPCAction
        }
        for id in actionIDs {
            if let action = pendingNPCDispatches.removeValue(forKey: id) {
                pendingNPCDispatchBytes -= action.payload.count
            }
        }
        revision &+= 1
        return actionIDs.count
    }

    public var queuedNPCActionCount: Int { scheduledNPCActions.count }
    public var queuedNPCActionBytes: Int { scheduledNPCActionBytes }
    public var pendingNPCDispatchCount: Int { pendingNPCDispatches.count }
    public var pendingNPCDispatchBytesCount: Int { pendingNPCDispatchBytes }
    /// Returns a reproducible SplitMix64 value for authoritative game decisions.
    /// The application defines what the value means; this method performs no simulation or I/O.
    public func nextDeterministicValue() throws -> UInt64 {
        guard phase == .active, let deterministicSeed else { throw GameServerError.invalidCoopTransition }
        deterministicDrawCount &+= 1
        revision &+= 1
        return Self.splitMix64(seed: deterministicSeed, counter: deterministicDrawCount)
    }

    /// Validates a durable random decision before it is appended to the write-ahead
    /// journal. The durable command path must call this before committing the event.
    public func validateDurableDeterministicDecision(by playerID: UUID) throws {
        guard phase == .active, deterministicSeed != nil,
              members.contains(playerID), disconnectedUntil[playerID] == nil,
              !abandonedMembers.contains(playerID) else {
            throw GameServerError.invalidCoopTransition
        }
    }

    /// Derives the stable value for a committed durable decision. Its journal sequence
    /// is the counter, so retries and replay after a later checkpoint return the same
    /// value without exposing the seed or mutating the simulation actor.
    public func deterministicValue(atJournalSequence sequence: UInt64) throws -> UInt64 {
        guard sequence > 0, let deterministicSeed else { throw GameServerError.invalidCoopTransition }
        return Self.splitMix64(seed: deterministicSeed, counter: sequence)
    }

    private static func splitMix64(seed: UInt64, counter: UInt64) -> UInt64 {
        var value = seed &+ (counter &* 0x9E3779B97F4A7C15)
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
    public func snapshot(for playerID: UUID) throws -> GameCoopSnapshot {
        guard members.contains(playerID) else { throw GameServerError.roomNotFoundOrUnauthorized }
        guard !abandonedMembers.contains(playerID) else { throw GameServerError.coopMemberAbandoned }
        guard disconnectedUntil[playerID] == nil else { throw GameServerError.coopMemberDisconnected }
        return GameCoopSnapshot(sessionID: sessionID, phase: phase, revision: revision, completedObjectives: completed,
                                objectiveProgress: progress,
                                deterministicDrawCount: deterministicDrawCount,
                                publicState: publicState, privatePlayerState: privateState.filter { $0.key == playerID })
    }
}

// MARK: - Bounded authoritative realtime/world primitives

public struct GameRealtimeInput: Sendable, Equatable {
    public let playerID: UUID
    public let clientSequence: UInt64
    public let payload: Data
    public init(playerID: UUID, clientSequence: UInt64, payload: Data) { self.playerID = playerID; self.clientSequence = clientSequence; self.payload = payload }
}

public struct GameRealtimeTick: Sendable, Equatable {
    public let tick: UInt64
    public let acceptedInputs: [GameRealtimeInput]
}

/// Bounded-cardinality overload counters for an authoritative realtime input queue.
public struct GameRealtimeSimulationMetrics: Sendable, Equatable {
    public let currentTick: UInt64
    public let isAcceptingInput: Bool
    public let queuedInputCount: Int
    public let queuedInputBytes: Int
    public let acceptedInputCount: UInt64
    public let capacityRejectionCount: UInt64
    public let oversizedInputRejectionCount: UInt64
    public let staleInputRejectionCount: UInt64
}

/// Fixed-step driver accepts bounded input and never waits for network or persistence I/O.
public actor GameRealtimeSimulation {
    private let maximumQueuedInputs: Int
    private let maximumInputBytes: Int
    private let maximumPlayers: Int
    private let maximumQueuedBytes: Int
    private let maximumQueuedInputsPerPlayer: Int
    private let maximumQueuedBytesPerPlayer: Int
    private var pending: [GameRealtimeInput] = []
    private var pendingHead = 0
    private var pendingBytes = 0
    private var queuedInputsByPlayer: [UUID: Int] = [:]
    private var queuedBytesByPlayer: [UUID: Int] = [:]
    private var lastSequence: [UUID: UInt64] = [:]
    private var tick: UInt64 = 0
    private var acceptedInputCount: UInt64 = 0
    private var capacityRejectionCount: UInt64 = 0
    private var oversizedInputRejectionCount: UInt64 = 0
    private var staleInputRejectionCount: UInt64 = 0
    private var inputAdmissionOpen = true
    public init(maximumQueuedInputs: Int = 4_096, maximumInputBytes: Int = 1_200, maximumPlayers: Int = 10_000,
                maximumQueuedBytes: Int = 4_194_304, maximumQueuedInputsPerPlayer: Int = 256,
                maximumQueuedBytesPerPlayer: Int = 262_144, initialTick: UInt64 = 0) throws {
        guard (1...1_000_000).contains(maximumQueuedInputs), (1...1_048_576).contains(maximumInputBytes),
              (1...1_000_000).contains(maximumPlayers), (1...1_073_741_824).contains(maximumQueuedBytes),
              (1...1_000_000).contains(maximumQueuedInputsPerPlayer),
              (1...1_073_741_824).contains(maximumQueuedBytesPerPlayer) else { throw GameServerError.invalidConfiguration }
        self.maximumQueuedInputs = maximumQueuedInputs; self.maximumInputBytes = maximumInputBytes
        self.maximumPlayers = maximumPlayers; self.maximumQueuedBytes = maximumQueuedBytes
        self.maximumQueuedInputsPerPlayer = maximumQueuedInputsPerPlayer
        self.maximumQueuedBytesPerPlayer = maximumQueuedBytesPerPlayer
        self.tick = initialTick
    }
    public func enqueue(_ input: GameRealtimeInput) throws {
        guard inputAdmissionOpen else {
            if capacityRejectionCount < .max { capacityRejectionCount += 1 }
            throw GameServerError.capacityReached
        }
        guard input.payload.count <= maximumInputBytes else {
            if oversizedInputRejectionCount < .max { oversizedInputRejectionCount += 1 }
            throw GameServerError.stateTooLarge
        }
        let playerInputCount = queuedInputsByPlayer[input.playerID, default: 0]
        let playerInputBytes = queuedBytesByPlayer[input.playerID, default: 0]
        guard playerInputCount < maximumQueuedInputsPerPlayer,
              input.payload.count <= maximumQueuedBytesPerPlayer,
              playerInputBytes <= maximumQueuedBytesPerPlayer - input.payload.count else {
            if capacityRejectionCount < .max { capacityRejectionCount += 1 }
            throw GameServerError.capacityReached
        }
        guard input.payload.count <= maximumQueuedBytes,
              pending.count - pendingHead < maximumQueuedInputs,
              pendingBytes <= maximumQueuedBytes - input.payload.count else {
            if capacityRejectionCount < .max { capacityRejectionCount += 1 }
            throw GameServerError.capacityReached
        }
        guard lastSequence[input.playerID] != nil || lastSequence.count < maximumPlayers else {
            if capacityRejectionCount < .max { capacityRejectionCount += 1 }
            throw GameServerError.capacityReached
        }
        guard input.clientSequence > (lastSequence[input.playerID] ?? 0) else {
            if staleInputRejectionCount < .max { staleInputRejectionCount += 1 }
            throw GameServerError.staleInput
        }
        lastSequence[input.playerID] = input.clientSequence; pending.append(input); pendingBytes += input.payload.count
        queuedInputsByPlayer[input.playerID] = playerInputCount + 1
        queuedBytesByPlayer[input.playerID] = playerInputBytes + input.payload.count
        if acceptedInputCount < .max { acceptedInputCount += 1 }
    }
    public func removePlayer(_ playerID: UUID) {
        lastSequence.removeValue(forKey: playerID)
        queuedInputsByPlayer.removeValue(forKey: playerID)
        queuedBytesByPlayer.removeValue(forKey: playerID)
        let remaining = pending.dropFirst(pendingHead).filter { $0.playerID != playerID }
        pending = Array(remaining); pendingHead = 0; pendingBytes = pending.reduce(0) { $0 + $1.payload.count }
    }
    /// Closes new input admission while preserving already queued inputs for recovery.
    public func closeInputAdmission() { inputAdmissionOpen = false }

    /// Reopens admission only after the application has drained or recovered queued input.
    public func resumeInputAdmission() throws {
        guard pending.count - pendingHead == 0 else { throw GameServerError.capacityReached }
        inputAdmissionOpen = true
    }

    public func advanceTick(maximumInputs: Int) throws -> GameRealtimeTick {
        guard maximumInputs > 0 else { throw GameServerError.invalidConfiguration }
        let (nextTick, tickOverflow) = tick.addingReportingOverflow(1)
        guard !tickOverflow else { throw GameServerError.tickExhausted }
        let end = pendingHead + min(maximumInputs, pending.count - pendingHead)
        let accepted = Array(pending[pendingHead..<end])
        for input in accepted {
            pendingBytes -= input.payload.count
            let remainingCount = queuedInputsByPlayer[input.playerID, default: 1] - 1
            let remainingBytes = queuedBytesByPlayer[input.playerID, default: input.payload.count] - input.payload.count
            if remainingCount == 0 {
                queuedInputsByPlayer.removeValue(forKey: input.playerID)
                queuedBytesByPlayer.removeValue(forKey: input.playerID)
            } else {
                queuedInputsByPlayer[input.playerID] = remainingCount
                queuedBytesByPlayer[input.playerID] = remainingBytes
            }
        }
        // The accepted tick owns its returned payloads. Release the queue's references
        // immediately instead of retaining consumed Data until array compaction.
        for index in pendingHead..<end {
            let consumed = pending[index]
            pending[index] = GameRealtimeInput(
                playerID: consumed.playerID,
                clientSequence: consumed.clientSequence,
                payload: Data()
            )
        }
        pendingHead = end; tick = nextTick
        if pendingHead > 1_024 && pendingHead > pending.count / 2 { pending.removeFirst(pendingHead); pendingHead = 0 }
        return GameRealtimeTick(tick: tick, acceptedInputs: accepted)
    }
    public var queuedInputCount: Int { pending.count - pendingHead }
    public var queuedInputBytes: Int { pendingBytes }
    public func queuedInputCount(for playerID: UUID) -> Int { queuedInputsByPlayer[playerID, default: 0] }
    public func queuedInputBytes(for playerID: UUID) -> Int { queuedBytesByPlayer[playerID, default: 0] }
    public var currentTick: UInt64 { tick }
    public func metrics() -> GameRealtimeSimulationMetrics {
        GameRealtimeSimulationMetrics(
            currentTick: tick,
            isAcceptingInput: inputAdmissionOpen,
            queuedInputCount: pending.count - pendingHead,
            queuedInputBytes: pendingBytes,
            acceptedInputCount: acceptedInputCount,
            capacityRejectionCount: capacityRejectionCount,
            oversizedInputRejectionCount: oversizedInputRejectionCount,
            staleInputRejectionCount: staleInputRejectionCount
        )
    }
}

public struct GameWorldConfiguration: Sendable, Equatable {
    public let maximumZones: Int
    public let maximumEntitiesPerZone: Int
    public let maximumEntityStateBytes: Int
    public let maximumStateBytesPerZone: Int
    public static let standard = GameWorldConfiguration(maximumZones: 64, maximumEntitiesPerZone: 100_000, maximumEntityStateBytes: 65_536, maximumStateBytesPerZone: 67_108_864, standard: ())
    public init(maximumZones: Int = 64, maximumEntitiesPerZone: Int = 100_000, maximumEntityStateBytes: Int = 65_536, maximumStateBytesPerZone: Int = 67_108_864) throws {
        guard (1...10_000).contains(maximumZones), (1...10_000_000).contains(maximumEntitiesPerZone),
              (1...1_048_576).contains(maximumEntityStateBytes), (1...1_073_741_824).contains(maximumStateBytesPerZone),
              maximumEntityStateBytes <= maximumStateBytesPerZone else { throw GameServerError.invalidConfiguration }
        self.maximumZones = maximumZones; self.maximumEntitiesPerZone = maximumEntitiesPerZone
        self.maximumEntityStateBytes = maximumEntityStateBytes; self.maximumStateBytesPerZone = maximumStateBytesPerZone
    }
    private init(maximumZones: Int, maximumEntitiesPerZone: Int, maximumEntityStateBytes: Int, maximumStateBytesPerZone: Int, standard: Void) {
        self.maximumZones = maximumZones; self.maximumEntitiesPerZone = maximumEntitiesPerZone
        self.maximumEntityStateBytes = maximumEntityStateBytes; self.maximumStateBytesPerZone = maximumStateBytesPerZone
    }
}

public struct GameWorldEntity: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let zoneID: UUID
    public let ownerID: UUID?
    public let fencingEpoch: UInt64
    public let state: Data

    public init(id: UUID, zoneID: UUID, ownerID: UUID?, fencingEpoch: UInt64, state: Data) {
        self.id = id
        self.zoneID = zoneID
        self.ownerID = ownerID
        self.fencingEpoch = fencingEpoch
        self.state = state
    }
}

/// Single-process zone/entity registry with explicit capacity and fencing epochs.
/// It is not a distributed MMO store; production multi-node adapters must persist leases.
public actor GameWorldRegistry {
    private let configuration: GameWorldConfiguration
    private var zones: [UUID: [UUID: GameWorldEntity]] = [:]
    private var entityEpochs: [UUID: UInt64] = [:]
    private var zoneBytes: [UUID: Int] = [:]
    public init(configuration: GameWorldConfiguration = .standard) { self.configuration = configuration }
    public func createZone(id: UUID = UUID()) throws -> UUID {
        guard zones[id] == nil else { throw GameServerError.zoneAlreadyExists }
        guard zones.count < configuration.maximumZones else { throw GameServerError.capacityReached }
        zones[id] = [:]; zoneBytes[id] = 0; return id
    }
    public func addEntity(zoneID: UUID, id: UUID = UUID(), ownerID: UUID? = nil, state: Data) throws -> GameWorldEntity {
        guard var entities = zones[zoneID] else { throw GameServerError.zoneNotFound }
        guard entityEpochs[id] == nil else { throw GameServerError.entityAlreadyExists }
        guard entities.count < configuration.maximumEntitiesPerZone else { throw GameServerError.capacityReached }
        guard state.count <= configuration.maximumEntityStateBytes,
              zoneBytes[zoneID, default: 0] <= configuration.maximumStateBytesPerZone - state.count else { throw GameServerError.stateTooLarge }
        let epoch: UInt64 = 1
        let entity = GameWorldEntity(id: id, zoneID: zoneID, ownerID: ownerID, fencingEpoch: epoch, state: state)
        entities[id] = entity; entityEpochs[id] = epoch; zones[zoneID] = entities; zoneBytes[zoneID, default: 0] += state.count; return entity
    }
    public func transfer(entityID: UUID, from source: UUID, to destination: UUID, expectedEpoch: UInt64) throws -> GameWorldEntity {
        guard source != destination else { throw GameServerError.invalidZoneTransfer }
        guard var sourceEntities = zones[source], var destinationEntities = zones[destination] else { throw GameServerError.zoneNotFound }
        guard let entity = sourceEntities[entityID] else { throw GameServerError.zoneNotFound }
        guard entityEpochs[entityID] == expectedEpoch, entity.fencingEpoch == expectedEpoch else { throw GameServerError.staleFence }
        guard destinationEntities.count < configuration.maximumEntitiesPerZone,
              zoneBytes[destination, default: 0] <= configuration.maximumStateBytesPerZone - entity.state.count else { throw GameServerError.capacityReached }
        sourceEntities.removeValue(forKey: entityID)
        zones[source] = sourceEntities; zoneBytes[source, default: 0] -= entity.state.count
        let newEpoch = expectedEpoch &+ 1; entityEpochs[entityID] = newEpoch
        let moved = GameWorldEntity(id: entity.id, zoneID: destination, ownerID: entity.ownerID, fencingEpoch: newEpoch, state: entity.state)
        destinationEntities[entityID] = moved; zones[destination] = destinationEntities
        zoneBytes[destination, default: 0] += moved.state.count
        return moved
    }
    public func removeEntity(zoneID: UUID, entityID: UUID, expectedEpoch: UInt64) throws {
        guard var entities = zones[zoneID], let entity = entities[entityID] else { throw GameServerError.zoneNotFound }
        guard entityEpochs[entityID] == expectedEpoch else { throw GameServerError.staleFence }
        entities.removeValue(forKey: entityID); zones[zoneID] = entities
        entityEpochs.removeValue(forKey: entityID); zoneBytes[zoneID, default: 0] -= entity.state.count
    }
    public func entities(in zoneID: UUID) -> [GameWorldEntity] { zones[zoneID]?.values.sorted { $0.id.uuidString < $1.id.uuidString } ?? [] }
}

// MARK: - Optional recovery contract

public protocol GameStateRecoveryStore: Sendable {
    func append(sessionID: UUID, epoch: UInt64, event: GameStateEvent) async throws
    func save(sessionID: UUID, epoch: UInt64, checkpoint: GameStateCheckpoint) async throws
    func load(sessionID: UUID) async throws -> (epoch: UInt64, checkpoint: GameStateCheckpoint, events: [GameStateEvent], latestSequence: UInt64)?
}

public enum GameServerError: Error, Sendable, Equatable {
    case invalidConfiguration, invalidSigningKey, ticketCapacityReached, invalidSessionOffer
    case capacityReached, roomFull, roomNotFoundOrUnauthorized, revisionConflict(current: UInt64), commandIDConflict
    case stateTooLarge, historyCapacityReached, staleInput, zoneAlreadyExists, zoneNotFound, staleFence, entityAlreadyExists, invalidZoneTransfer
    case invalidMatchTicket, playerAlreadyQueued, invalidCoopTransition, objectivePrerequisitesIncomplete
    case invalidObjectiveProgress, objectiveProgressIncomplete, invalidNPCAction, npcActionIDConflict, npcActionCapacityReached
    case coopMemberDisconnected, coopReconnectExpired, coopMemberAbandoned
    case invalidCheckpoint, tickExhausted
}

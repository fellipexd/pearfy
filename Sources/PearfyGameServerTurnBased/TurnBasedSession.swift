import Foundation
import PearfyGameServer

public enum GameTurnBasedStoreResult: Sendable, Equatable {
    case appended(GameStateEvent)
    case duplicate(GameStateEvent)
}

/// Bounded recovery/synchronization page. A nil cursor requests a full snapshot;
/// subsequent requests pass the returned cursor to fetch the event suffix.
/// The state and event payloads are server data and must be projected/authorized
/// by the application before they are sent to a client.
public struct GameTurnBasedSyncPage: Sendable, Equatable {
    public let snapshot: Data?
    public let events: [GameStateEvent]
    public let cursor: UInt64
    public let revision: UInt64
    public let hasMore: Bool
    /// Sum of snapshot bytes, or event payload and resulting-state bytes.
    public let payloadBytes: Int
}

/// Implementations must atomically compare the revision, append the immutable event,
/// and deduplicate retries by command ID bound to player and exact payload bytes.
/// A duplicate retry must return the original event even if its first append committed
/// but the caller lost the response, provided no later command has advanced the session.
/// If storage has moved ahead of this session actor, return a revision conflict so it
/// reopens instead of publishing stale state. A revision conflict fails closed.
public protocol GameTurnBasedCommandStore: Sendable {
    func load(sessionID: UUID) async throws -> GameStateCheckpoint?
    func append(
        sessionID: UUID,
        expectedRevision: UInt64,
        event: GameStateEvent
    ) async throws -> GameTurnBasedStoreResult
}

public enum GameTurnBasedSessionError: Error, Sendable, Equatable {
    case invalidConfiguration
    case invalidCheckpoint
    case commitInProgress
    case storeContractViolation
    case invalidPageRequest
    case eventExceedsPageByteLimit
}

/// Server-authoritative command session for finite turn-based and point-and-click games.
/// The injected store owns durability; append completes before this actor publishes state.
public actor GameTurnBasedSession {
    public typealias Reducer = @Sendable (_ currentState: Data, _ playerID: UUID, _ command: Data) async throws -> Data

    public let sessionID: UUID
    private let store: any GameTurnBasedCommandStore
    private let reducer: Reducer
    private let maximumEvents: Int
    private let maximumStateBytes: Int
    private let maximumHistoryBytes: Int
    private let maximumCommandBytes: Int
    private var historyBytes = 0
    private var state: Data
    private var revision: UInt64 = 0
    private var events: [GameStateEvent] = []
    private var processed: [UUID: GameStateEvent] = [:]
    private var commitInProgress = false

    private init(sessionID: UUID, initialState: Data, store: any GameTurnBasedCommandStore,
                 reducer: @escaping Reducer, maximumEvents: Int, maximumStateBytes: Int,
                 maximumHistoryBytes: Int, maximumCommandBytes: Int) {
        self.sessionID = sessionID
        self.state = initialState
        self.store = store
        self.reducer = reducer
        self.maximumEvents = maximumEvents
        self.maximumStateBytes = maximumStateBytes
        self.maximumHistoryBytes = maximumHistoryBytes
        self.maximumCommandBytes = maximumCommandBytes
    }

    /// Loads the bounded event history and verifies every state by replay before use.
    /// A missing record creates a fresh session at revision zero.
    public static func open(
        sessionID: UUID,
        initialState: Data,
        store: any GameTurnBasedCommandStore,
        maximumEvents: Int = 10_000,
        maximumStateBytes: Int = 1_048_576,
        maximumHistoryBytes: Int = 67_108_864,
        maximumCommandBytes: Int = 65_536,
        reducer: @escaping Reducer
    ) async throws -> GameTurnBasedSession {
        guard (1...100_000).contains(maximumEvents), (1...16_777_216).contains(maximumStateBytes),
              (1...1_073_741_824).contains(maximumHistoryBytes),
              (1...1_048_576).contains(maximumCommandBytes), initialState.count <= maximumStateBytes else {
            throw GameTurnBasedSessionError.invalidConfiguration
        }
        let session = GameTurnBasedSession(sessionID: sessionID, initialState: initialState,
            store: store, reducer: reducer, maximumEvents: maximumEvents,
            maximumStateBytes: maximumStateBytes, maximumHistoryBytes: maximumHistoryBytes,
            maximumCommandBytes: maximumCommandBytes)
        guard let checkpoint = try await store.load(sessionID: sessionID) else { return session }
        try await session.restore(checkpoint, initialState: initialState)
        return session
    }

    public func submit(
        commandID: UUID,
        playerID: UUID,
        command: Data,
        expectedRevision: UInt64? = nil
    ) async throws -> GameCommandResult {
        if let previous = processed[commandID] {
            guard previous.playerID == playerID, previous.payload == command else {
                throw GameServerError.commandIDConflict
            }
            return .duplicate(previous)
        }
        guard !commitInProgress else { throw GameTurnBasedSessionError.commitInProgress }
        if let expectedRevision, expectedRevision != revision {
            throw GameServerError.revisionConflict(current: revision)
        }
        guard events.count < maximumEvents else { throw GameServerError.capacityReached }
        guard command.count <= maximumCommandBytes else { throw GameServerError.stateTooLarge }

        commitInProgress = true
        defer { commitInProgress = false }
        let nextState = try await reducer(state, playerID, command)
        guard nextState.count <= maximumStateBytes else { throw GameServerError.stateTooLarge }
        guard command.count <= maximumHistoryBytes,
              nextState.count <= maximumHistoryBytes - command.count,
              historyBytes <= maximumHistoryBytes - command.count - nextState.count else {
            throw GameServerError.historyCapacityReached
        }
        let event = GameStateEvent(sequence: revision &+ 1, commandID: commandID,
            playerID: playerID, payload: command, state: nextState)
        let result = try await store.append(sessionID: sessionID, expectedRevision: revision, event: event)
        let storedEvent: GameStateEvent
        let wasDuplicate: Bool
        switch result {
        case .appended(let appended): storedEvent = appended; wasDuplicate = false
        case .duplicate(let duplicate): storedEvent = duplicate; wasDuplicate = true
        }
        guard storedEvent == event, storedEvent.sequence == revision &+ 1 else {
            throw GameTurnBasedSessionError.storeContractViolation
        }
        publish(storedEvent)
        return wasDuplicate ? .duplicate(storedEvent) : .applied(storedEvent)
    }

    public func checkpoint() -> GameStateCheckpoint {
        GameStateCheckpoint(revision: revision, state: state, events: events)
    }

    public func events(after sequence: UInt64) -> [GameStateEvent] {
        events.filter { $0.sequence > sequence }
    }

    /// Returns a full state snapshot when `afterRevision` is nil, or a contiguous
    /// event page after the supplied cursor. Limits apply before returning data.
    public func syncPage(
        afterRevision: UInt64? = nil,
        maximumEvents pageLimit: Int = 100,
        maximumBytes: Int = 1_048_576
    ) throws -> GameTurnBasedSyncPage {
        guard (1...1_000).contains(pageLimit), (1...16_777_216).contains(maximumBytes) else {
            throw GameTurnBasedSessionError.invalidPageRequest
        }
        guard let afterRevision else {
            guard state.count <= maximumBytes else { throw GameTurnBasedSessionError.eventExceedsPageByteLimit }
            return GameTurnBasedSyncPage(
                snapshot: state, events: [], cursor: revision, revision: revision,
                hasMore: false, payloadBytes: state.count
            )
        }
        guard afterRevision <= revision else { throw GameTurnBasedSessionError.invalidPageRequest }

        var page: [GameStateEvent] = []
        var bytes = 0
        var cursor = afterRevision
        for event in events where event.sequence > afterRevision {
            let (eventBytes, overflow) = event.payload.count.addingReportingOverflow(event.state.count)
            guard !overflow else { throw GameTurnBasedSessionError.eventExceedsPageByteLimit }
            guard eventBytes <= maximumBytes else { throw GameTurnBasedSessionError.eventExceedsPageByteLimit }
            if page.count == pageLimit || bytes > maximumBytes - eventBytes { break }
            // The in-memory history is contiguous by construction; fail closed if
            // corrupted state ever violates that invariant.
            guard event.sequence == cursor &+ 1 else { throw GameTurnBasedSessionError.invalidCheckpoint }
            page.append(event)
            bytes += eventBytes
            cursor = event.sequence
        }
        let hasMore = events.contains { $0.sequence > cursor }
        return GameTurnBasedSyncPage(
            snapshot: nil, events: page, cursor: cursor, revision: revision,
            hasMore: hasMore, payloadBytes: bytes
        )
    }

    public var currentRevision: UInt64 { revision }

    public func currentState() -> Data { state }

    private func restore(_ checkpoint: GameStateCheckpoint, initialState: Data) async throws {
        guard checkpoint.state.count <= maximumStateBytes,
              checkpoint.events.count <= maximumEvents,
              checkpoint.revision == UInt64(checkpoint.events.count) else {
            throw GameTurnBasedSessionError.invalidCheckpoint
        }
        var replayedState = initialState
        var replayedBytes = 0
        var seenCommandIDs = Set<UUID>()
        for (index, event) in checkpoint.events.enumerated() {
            guard event.sequence == UInt64(index) &+ 1,
                  event.payload.count <= maximumCommandBytes,
                  event.state.count <= maximumStateBytes,
                  seenCommandIDs.insert(event.commandID).inserted,
                  event.payload.count <= maximumHistoryBytes,
                  event.state.count <= maximumHistoryBytes - event.payload.count,
                  replayedBytes <= maximumHistoryBytes - event.payload.count - event.state.count else {
                throw GameTurnBasedSessionError.invalidCheckpoint
            }
            let next = try await reducer(replayedState, event.playerID, event.payload)
            guard next == event.state, next.count <= maximumStateBytes else {
                throw GameTurnBasedSessionError.invalidCheckpoint
            }
            replayedState = next
            replayedBytes += event.payload.count + event.state.count
        }
        guard replayedState == checkpoint.state else { throw GameTurnBasedSessionError.invalidCheckpoint }
        state = checkpoint.state
        revision = checkpoint.revision
        events = checkpoint.events
        historyBytes = replayedBytes
        processed = Dictionary(uniqueKeysWithValues: checkpoint.events.map { ($0.commandID, $0) })
    }

    private func publish(_ event: GameStateEvent) {
        state = event.state
        revision = event.sequence
        events.append(event)
        processed[event.commandID] = event
        historyBytes += event.payload.count + event.state.count
    }
}

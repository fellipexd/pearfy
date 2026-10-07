import Foundation
import PearfyGameServer
import PearfyGameServerTurnBased
import Testing

private enum TurnBasedStoreTestError: Error {
    case lostResponse
    case invalidCommand
}

private actor MemoryTurnBasedStore: GameTurnBasedCommandStore {
    private var checkpoint: GameStateCheckpoint?
    private var loseNextAppendResponse = false

    func load(sessionID: UUID) async throws -> GameStateCheckpoint? { checkpoint }

    func loseNextResponseAfterCommit() { loseNextAppendResponse = true }

    func append(sessionID: UUID, expectedRevision: UInt64, event: GameStateEvent) async throws -> GameTurnBasedStoreResult {
        if let previous = checkpoint?.events.first(where: { $0.commandID == event.commandID }) {
            guard previous.playerID == event.playerID, previous.payload == event.payload else {
                throw GameServerError.commandIDConflict
            }
            return .duplicate(previous)
        }
        let revision = checkpoint?.revision ?? 0
        guard revision == expectedRevision, event.sequence == revision + 1 else {
            throw GameServerError.revisionConflict(current: revision)
        }
        var events = checkpoint?.events ?? []
        events.append(event)
        checkpoint = GameStateCheckpoint(revision: event.sequence, state: event.state, events: events)
        if loseNextAppendResponse {
            loseNextAppendResponse = false
            throw TurnBasedStoreTestError.lostResponse
        }
        return .appended(event)
    }
}

private func integerReducer(_ state: Data, _ playerID: UUID, _ command: Data) async throws -> Data {
    guard let current = Int(String(decoding: state, as: UTF8.self)),
          let delta = Int(String(decoding: command, as: UTF8.self)), delta > 0 else {
        throw TurnBasedStoreTestError.invalidCommand
    }
    return Data(String(current + delta).utf8)
}

@Test func turnBasedSessionAppendsBeforePublishingAndRetriesAmbiguousCommit() async throws {
    let store = MemoryTurnBasedStore()
    let sessionID = UUID()
    let playerID = UUID()
    let commandID = UUID()
    let session = try await GameTurnBasedSession.open(
        sessionID: sessionID, initialState: Data("0".utf8), store: store, reducer: integerReducer
    )
    await store.loseNextResponseAfterCommit()

    await #expect(throws: TurnBasedStoreTestError.self) {
        try await session.submit(commandID: commandID, playerID: playerID, command: Data("2".utf8))
    }
    #expect(await session.currentRevision == 0)
    #expect(await session.currentState() == Data("0".utf8))

    let retry = try await session.submit(commandID: commandID, playerID: playerID, command: Data("2".utf8))
    #expect(retry == .duplicate(GameStateEvent(
        sequence: 1, commandID: commandID, playerID: playerID, payload: Data("2".utf8), state: Data("2".utf8)
    )))
    #expect(await session.currentRevision == 1)
    #expect(await session.currentState() == Data("2".utf8))
}

@Test func turnBasedSessionReplaysCheckpointAndDeduplicatesCommands() async throws {
    let store = MemoryTurnBasedStore()
    let sessionID = UUID()
    let playerID = UUID()
    let commandID = UUID()
    let first = try await GameTurnBasedSession.open(
        sessionID: sessionID, initialState: Data("0".utf8), store: store, reducer: integerReducer
    )
    _ = try await first.submit(commandID: commandID, playerID: playerID, command: Data("4".utf8))

    let restored = try await GameTurnBasedSession.open(
        sessionID: sessionID, initialState: Data("0".utf8), store: store, reducer: integerReducer
    )
    #expect(await restored.currentRevision == 1)
    #expect(await restored.currentState() == Data("4".utf8))
    let duplicate = try await restored.submit(commandID: commandID, playerID: playerID, command: Data("4".utf8))
    #expect(duplicate == .duplicate(try #require(await restored.events(after: 0).first)))
}

@Test func turnBasedSessionRejectsInvalidCommandWithoutMutatingState() async throws {
    let session = try await GameTurnBasedSession.open(
        sessionID: UUID(), initialState: Data("3".utf8), store: MemoryTurnBasedStore(), reducer: integerReducer
    )
    await #expect(throws: TurnBasedStoreTestError.self) {
        try await session.submit(commandID: UUID(), playerID: UUID(), command: Data("-1".utf8))
    }
    #expect(await session.currentRevision == 0)
    #expect(await session.currentState() == Data("3".utf8))
}

@Test func turnBasedSessionPagesSnapshotAndContiguousEventCursorWithinByteBudget() async throws {
    let session = try await GameTurnBasedSession.open(
        sessionID: UUID(), initialState: Data("0".utf8), store: MemoryTurnBasedStore(), reducer: integerReducer
    )
    for value in 1...3 {
        _ = try await session.submit(commandID: UUID(), playerID: UUID(), command: Data("\(value)".utf8))
    }

    let snapshot = try await session.syncPage()
    #expect(snapshot.snapshot == Data("6".utf8))
    #expect(snapshot.events.isEmpty)
    #expect(snapshot.cursor == 3)
    #expect(snapshot.revision == 3)
    #expect(snapshot.payloadBytes == 1)

    let firstPage = try await session.syncPage(afterRevision: 0, maximumEvents: 2, maximumBytes: 4)
    #expect(firstPage.snapshot == nil)
    #expect(firstPage.events.map(\.sequence) == [1, 2])
    #expect(firstPage.cursor == 2)
    #expect(firstPage.hasMore)
    #expect(firstPage.payloadBytes == 4)

    let lastPage = try await session.syncPage(afterRevision: firstPage.cursor, maximumEvents: 2, maximumBytes: 4)
    #expect(lastPage.events.map(\.sequence) == [3])
    #expect(lastPage.cursor == 3)
    #expect(!lastPage.hasMore)
}

@Test func turnBasedSessionSyncRejectsFutureCursorsAndOversizedFirstItem() async throws {
    let session = try await GameTurnBasedSession.open(
        sessionID: UUID(), initialState: Data("0".utf8), store: MemoryTurnBasedStore(), reducer: integerReducer
    )
    _ = try await session.submit(commandID: UUID(), playerID: UUID(), command: Data("2".utf8))
    await #expect(throws: GameTurnBasedSessionError.invalidPageRequest) {
        try await session.syncPage(afterRevision: 2)
    }
    await #expect(throws: GameTurnBasedSessionError.eventExceedsPageByteLimit) {
        try await session.syncPage(afterRevision: 0, maximumBytes: 1)
    }
}

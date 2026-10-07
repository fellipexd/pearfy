import Foundation
import PearfyGameServerRealtime
import Testing

@Test func realtimeInterestManagerBuildsBoundedSpatialPagesAndRejectsStaleCursors() async throws {
    let manager = GameRealtimeInterestManager(configuration: try GameRealtimeInterestConfiguration(
        cellSize: 10,
        maximumRadiusCells: 2,
        maximumEntities: 4,
        maximumEntityStateBytes: 8,
        maximumTotalStateBytes: 12,
        maximumQueryCandidates: 4,
        maximumPageEntities: 2,
        maximumPageBytes: 8
    ))
    let negative = GameRealtimeSpatialEntity(id: UUID(), revision: 1, position: .init(x: -1, y: 0), state: Data([1]))
    let center = GameRealtimeSpatialEntity(id: UUID(), revision: 1, position: .init(x: 0, y: 0), state: Data([2]))
    let edge = GameRealtimeSpatialEntity(id: UUID(), revision: 1, position: .init(x: 10, y: 0), state: Data([3]))
    let outside = GameRealtimeSpatialEntity(id: UUID(), revision: 1, position: .init(x: 30, y: 0), state: Data([4]))
    _ = try await manager.upsert(negative)
    _ = try await manager.upsert(center)
    let firstRevision = try await manager.upsert(edge)
    _ = try await manager.upsert(outside)

    let firstPage = try await manager.snapshot(around: .init(x: 0, y: 0), radiusCells: 1, limit: 1)
    #expect(firstPage.totalVisibleEntities == 3)
    #expect(firstPage.entities.count == 1)
    let nextOffset = try #require(firstPage.nextOffset)
    let secondPage = try await manager.snapshot(
        around: .init(x: 0, y: 0), radiusCells: 1, offset: nextOffset,
        expectedWorldRevision: firstPage.worldRevision
    )
    #expect(secondPage.entities.count == 2)
    #expect(firstPage.entities.count + secondPage.entities.count == firstPage.totalVisibleEntities)
    #expect(secondPage.worldRevision == firstRevision + 1)

    _ = try await manager.upsert(GameRealtimeSpatialEntity(
        id: negative.id, revision: 2, position: .init(x: 100, y: 0), state: Data([5])
    ))
    do {
        _ = try await manager.snapshot(
            around: .init(x: 0, y: 0), radiusCells: 1, offset: nextOffset,
            expectedWorldRevision: firstPage.worldRevision
        )
        Issue.record("a cursor from a prior world revision must not continue after mutations")
    } catch {
        #expect(error as? GameRealtimeInterestError == .worldChanged)
    }
    let updatedMetrics = await manager.metrics()
    #expect(updatedMetrics.entityCount == 4)
    #expect(updatedMetrics.retainedStateBytes == 4)
    #expect(updatedMetrics.worldRevision == firstRevision + 2)
}

@Test func realtimeInterestManagerEnforcesMemoryCandidateAndRevisionLimits() async throws {
    let manager = GameRealtimeInterestManager(configuration: try GameRealtimeInterestConfiguration(
        cellSize: 10,
        maximumRadiusCells: 1,
        maximumEntities: 2,
        maximumEntityStateBytes: 4,
        maximumTotalStateBytes: 4,
        maximumQueryCandidates: 1,
        maximumPageEntities: 1,
        maximumPageBytes: 4
    ))
    let first = GameRealtimeSpatialEntity(id: UUID(), revision: 1, position: .init(x: 0, y: 0), state: Data([1, 2]))
    _ = try await manager.upsert(first)
    do {
        _ = try await manager.upsert(GameRealtimeSpatialEntity(
            id: first.id, revision: 2, position: .init(x: 1, y: 0), state: Data([1, 2, 3, 4, 5])
        ))
        Issue.record("oversized entity state must be rejected before replacing the existing entity")
    } catch {
        #expect(error as? GameRealtimeInterestError == .entityStateTooLarge)
    }
    do {
        _ = try await manager.upsert(GameRealtimeSpatialEntity(
            id: UUID(), revision: 1, position: .init(x: 2, y: 0), state: Data([3, 4, 5])
        ))
        Issue.record("aggregate state bytes must remain bounded")
    } catch {
        #expect(error as? GameRealtimeInterestError == .capacityReached)
    }
    do {
        _ = try await manager.upsert(GameRealtimeSpatialEntity(
            id: first.id, revision: 1, position: .init(x: 1, y: 0), state: Data([1])
        ))
        Issue.record("entity revisions must increase")
    } catch {
        #expect(error as? GameRealtimeInterestError == .staleEntityRevision)
    }

    let second = GameRealtimeSpatialEntity(id: UUID(), revision: 1, position: .init(x: 1, y: 0), state: Data([2]))
    _ = try await manager.upsert(second)
    do {
        _ = try await manager.snapshot(around: .init(x: 0, y: 0), radiusCells: 1)
        Issue.record("candidate scans must stop at the configured work budget")
    } catch {
        #expect(error as? GameRealtimeInterestError == .capacityReached)
    }
    #expect(try await manager.remove(entityID: first.id))
    let metrics = await manager.metrics()
    #expect(metrics.entityCount == 1 && metrics.retainedStateBytes == 1)
}

@Test func realtimeInterestDeltaConvergesWithBoundedPagesAndRejectsStaleCursors() async throws {
    let manager = GameRealtimeInterestManager(configuration: try GameRealtimeInterestConfiguration(
        cellSize: 10,
        maximumRadiusCells: 2,
        maximumEntities: 8,
        maximumEntityStateBytes: 8,
        maximumTotalStateBytes: 64,
        maximumQueryCandidates: 8,
        maximumPageEntities: 1,
        maximumPageBytes: 8
    ))
    let retained = GameRealtimeSpatialEntity(id: UUID(), revision: 1, position: .init(x: 0, y: 0), state: Data([1]))
    let departing = GameRealtimeSpatialEntity(id: UUID(), revision: 1, position: .init(x: 10, y: 0), state: Data([2]))
    _ = try await manager.upsert(retained)
    let baseRevision = try await manager.upsert(departing)

    _ = try await manager.upsert(GameRealtimeSpatialEntity(
        id: retained.id, revision: 2, position: .init(x: 0, y: 0), state: Data([3])
    ))
    _ = try await manager.upsert(GameRealtimeSpatialEntity(
        id: departing.id, revision: 2, position: .init(x: 50, y: 0), state: Data([4])
    ))
    let entering = GameRealtimeSpatialEntity(id: UUID(), revision: 1, position: .init(x: -1, y: 0), state: Data([5]))
    let currentRevision = try await manager.upsert(entering)

    let previousVisible: Set<UUID> = [retained.id, departing.id]
    var page = try await manager.delta(
        around: .init(x: 0, y: 0), radiusCells: 1, since: baseRevision,
        previousVisibleEntityIDs: previousVisible, limit: 8
    )
    #expect(page.totalChanges == 3)
    #expect(page.changes.count == 1)
    var updatedVisible = previousVisible
    var applied = page.changes
    if let nextOffset = page.nextOffset {
        page = try await manager.delta(
            around: .init(x: 0, y: 0), radiusCells: 1, since: baseRevision,
            previousVisibleEntityIDs: previousVisible, offset: nextOffset, limit: 8,
            expectedWorldRevision: page.worldRevision
        )
        applied += page.changes
    }
    if let nextOffset = page.nextOffset {
        page = try await manager.delta(
            around: .init(x: 0, y: 0), radiusCells: 1, since: baseRevision,
            previousVisibleEntityIDs: previousVisible, offset: nextOffset, limit: 8,
            expectedWorldRevision: page.worldRevision
        )
        applied += page.changes
    }
    #expect(page.nextOffset == nil)
    #expect(page.worldRevision == currentRevision)
    for change in applied {
        switch change {
        case .upsert(let entity): updatedVisible.insert(entity.id)
        case .remove(let entityID): updatedVisible.remove(entityID)
        }
    }
    #expect(updatedVisible == [retained.id, entering.id])
    #expect(applied.contains(.upsert(GameRealtimeSpatialEntity(
        id: retained.id, revision: 2, position: .init(x: 0, y: 0), state: Data([3])
    ))))
    #expect(applied.contains(.remove(departing.id)))

    do {
        _ = try await manager.delta(
            around: .init(x: 0, y: 0), radiusCells: 1, since: baseRevision,
            previousVisibleEntityIDs: previousVisible, offset: 1,
            expectedWorldRevision: currentRevision - 1
        )
        Issue.record("a page cursor must be invalid after any world mutation")
    } catch {
        #expect(error as? GameRealtimeInterestError == .worldChanged)
    }
}

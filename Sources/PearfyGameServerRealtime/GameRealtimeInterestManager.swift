import Foundation

public struct GameRealtimePosition: Sendable, Equatable {
    public let x: Int32
    public let y: Int32

    public init(x: Int32, y: Int32) {
        self.x = x
        self.y = y
    }
}

public struct GameRealtimeSpatialEntity: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let revision: UInt64
    public let position: GameRealtimePosition
    public let state: Data

    public init(id: UUID, revision: UInt64, position: GameRealtimePosition, state: Data) {
        self.id = id
        self.revision = revision
        self.position = position
        self.state = state
    }
}

public struct GameRealtimeInterestPage: Sendable, Equatable {
    public let worldRevision: UInt64
    public let totalVisibleEntities: Int
    public let entities: [GameRealtimeSpatialEntity]
    public let nextOffset: Int?
}

public enum GameRealtimeInterestChange: Sendable, Equatable, Identifiable {
    case upsert(GameRealtimeSpatialEntity)
    case remove(UUID)

    public var id: UUID {
        switch self {
        case .upsert(let entity): entity.id
        case .remove(let entityID): entityID
        }
    }

    fileprivate var payloadBytes: Int {
        switch self {
        case .upsert(let entity): entity.state.count
        case .remove: 0
        }
    }
}

public struct GameRealtimeInterestDeltaPage: Sendable, Equatable {
    public let baseWorldRevision: UInt64
    public let worldRevision: UInt64
    public let totalChanges: Int
    public let changes: [GameRealtimeInterestChange]
    public let nextOffset: Int?
}

public struct GameRealtimeInterestMetrics: Sendable, Equatable {
    public let entityCount: Int
    public let retainedStateBytes: Int
    public let worldRevision: UInt64
}

public struct GameRealtimeInterestConfiguration: Sendable, Equatable {
    public let cellSize: Int32
    public let maximumRadiusCells: Int
    public let maximumEntities: Int
    public let maximumEntityStateBytes: Int
    public let maximumTotalStateBytes: Int
    public let maximumQueryCandidates: Int
    public let maximumPageEntities: Int
    public let maximumPageBytes: Int

    public init(
        cellSize: Int32 = 100,
        maximumRadiusCells: Int = 32,
        maximumEntities: Int = 100_000,
        maximumEntityStateBytes: Int = 4_096,
        maximumTotalStateBytes: Int = 67_108_864,
        maximumQueryCandidates: Int = 10_000,
        maximumPageEntities: Int = 256,
        maximumPageBytes: Int = 524_288
    ) throws {
        guard cellSize > 0,
              (0...64).contains(maximumRadiusCells),
              (1...1_000_000).contains(maximumEntities),
              (1...1_048_576).contains(maximumEntityStateBytes),
              (1...1_073_741_824).contains(maximumTotalStateBytes),
              maximumEntityStateBytes <= maximumTotalStateBytes,
              (1...maximumEntities).contains(maximumQueryCandidates),
              (1...1_000).contains(maximumPageEntities),
              (1...16_777_216).contains(maximumPageBytes),
              maximumEntityStateBytes <= maximumPageBytes else {
            throw GameRealtimeInterestError.invalidConfiguration
        }
        self.cellSize = cellSize
        self.maximumRadiusCells = maximumRadiusCells
        self.maximumEntities = maximumEntities
        self.maximumEntityStateBytes = maximumEntityStateBytes
        self.maximumTotalStateBytes = maximumTotalStateBytes
        self.maximumQueryCandidates = maximumQueryCandidates
        self.maximumPageEntities = maximumPageEntities
        self.maximumPageBytes = maximumPageBytes
    }
}

public enum GameRealtimeInterestError: Error, Sendable, Equatable {
    case invalidConfiguration
    case capacityReached
    case entityStateTooLarge
    case staleEntityRevision
    case worldChanged
    case invalidQuery
    case revisionExhausted
}

/// Bounded spatial index for server-authoritative AOI snapshots. Coordinates use
/// application-defined integer units; query radii are square cell ranges.
public actor GameRealtimeInterestManager {
    private struct Cell: Hashable {
        let x: Int64
        let y: Int64
    }

    private let configuration: GameRealtimeInterestConfiguration
    private var entities: [UUID: GameRealtimeSpatialEntity] = [:]
    private var changedAtWorldRevision: [UUID: UInt64] = [:]
    private var cellByEntity: [UUID: Cell] = [:]
    private var entitiesByCell: [Cell: Set<UUID>] = [:]
    private var retainedStateBytes = 0
    private var revision: UInt64 = 0

    public init(configuration: GameRealtimeInterestConfiguration) {
        self.configuration = configuration
    }

    @discardableResult
    public func upsert(_ entity: GameRealtimeSpatialEntity) throws -> UInt64 {
        guard entity.state.count <= configuration.maximumEntityStateBytes else {
            throw GameRealtimeInterestError.entityStateTooLarge
        }
        if let previous = entities[entity.id] {
            guard entity.revision > previous.revision else { throw GameRealtimeInterestError.staleEntityRevision }
        } else if entities.count >= configuration.maximumEntities {
            throw GameRealtimeInterestError.capacityReached
        }

        let previous = entities[entity.id]
        let bytesWithoutPrevious = retainedStateBytes - (previous?.state.count ?? 0)
        guard entity.state.count <= configuration.maximumTotalStateBytes,
              bytesWithoutPrevious <= configuration.maximumTotalStateBytes - entity.state.count else {
            throw GameRealtimeInterestError.capacityReached
        }
        let (nextRevision, revisionOverflow) = revision.addingReportingOverflow(1)
        guard !revisionOverflow else { throw GameRealtimeInterestError.revisionExhausted }

        let newCell = cell(for: entity.position)
        if let oldCell = cellByEntity[entity.id], oldCell != newCell {
            entitiesByCell[oldCell]?.remove(entity.id)
            if entitiesByCell[oldCell]?.isEmpty == true { entitiesByCell.removeValue(forKey: oldCell) }
        }
        entities[entity.id] = entity
        changedAtWorldRevision[entity.id] = nextRevision
        cellByEntity[entity.id] = newCell
        entitiesByCell[newCell, default: []].insert(entity.id)
        retainedStateBytes = bytesWithoutPrevious + entity.state.count
        revision = nextRevision
        return revision
    }

    @discardableResult
    public func remove(entityID: UUID) throws -> Bool {
        guard let entity = entities[entityID], let cell = cellByEntity[entityID] else { return false }
        let (nextRevision, revisionOverflow) = revision.addingReportingOverflow(1)
        guard !revisionOverflow else { throw GameRealtimeInterestError.revisionExhausted }
        entities.removeValue(forKey: entityID)
        changedAtWorldRevision.removeValue(forKey: entityID)
        cellByEntity.removeValue(forKey: entityID)
        entitiesByCell[cell]?.remove(entityID)
        if entitiesByCell[cell]?.isEmpty == true { entitiesByCell.removeValue(forKey: cell) }
        retainedStateBytes -= entity.state.count
        revision = nextRevision
        return true
    }

    /// Pages one consistent world revision. Pass the returned revision on subsequent
    /// pages; if the world changed, restart from offset zero to avoid gaps or duplicates.
    public func snapshot(
        around center: GameRealtimePosition,
        radiusCells: Int,
        offset: Int = 0,
        limit: Int = 100,
        expectedWorldRevision: UInt64? = nil
    ) throws -> GameRealtimeInterestPage {
        guard (0...configuration.maximumRadiusCells).contains(radiusCells),
              offset >= 0,
              limit > 0 else {
            throw GameRealtimeInterestError.invalidQuery
        }
        let boundedLimit = min(limit, configuration.maximumPageEntities)
        if let expectedWorldRevision, expectedWorldRevision != revision {
            throw GameRealtimeInterestError.worldChanged
        }

        let visible = try visibleEntities(around: center, radiusCells: radiusCells)

        let total = visible.count
        guard offset <= total else { throw GameRealtimeInterestError.invalidQuery }
        let end = min(total, offset + boundedLimit)
        var page: [GameRealtimeSpatialEntity] = []
        var pageBytes = 0
        for entity in visible[offset..<end] {
            let (nextBytes, overflow) = pageBytes.addingReportingOverflow(entity.state.count)
            guard !overflow, nextBytes <= configuration.maximumPageBytes else {
                if page.isEmpty { throw GameRealtimeInterestError.capacityReached }
                break
            }
            page.append(entity)
            pageBytes = nextBytes
        }
        let nextOffset = offset + page.count < total ? offset + page.count : nil
        return GameRealtimeInterestPage(
            worldRevision: revision,
            totalVisibleEntities: total,
            entities: page,
            nextOffset: nextOffset
        )
    }

    /// Produces a bounded AOI delta against the caller's prior visible entity IDs.
    /// The caller applies every page, then stores the returned world revision as its
    /// next base revision. A world mutation between pages invalidates the cursor.
    public func delta(
        around center: GameRealtimePosition,
        radiusCells: Int,
        since baseWorldRevision: UInt64,
        previousVisibleEntityIDs: Set<UUID>,
        offset: Int = 0,
        limit: Int = 100,
        expectedWorldRevision: UInt64? = nil
    ) throws -> GameRealtimeInterestDeltaPage {
        guard (0...configuration.maximumRadiusCells).contains(radiusCells),
              offset >= 0,
              limit > 0,
              baseWorldRevision <= revision,
              previousVisibleEntityIDs.count <= configuration.maximumQueryCandidates else {
            throw GameRealtimeInterestError.invalidQuery
        }
        if let expectedWorldRevision, expectedWorldRevision != revision {
            throw GameRealtimeInterestError.worldChanged
        }

        let visible = try visibleEntities(around: center, radiusCells: radiusCells)
        let visibleIDs = Set(visible.lazy.map(\.id))
        var changes: [GameRealtimeInterestChange] = []
        changes.reserveCapacity(min(configuration.maximumQueryCandidates, visible.count + previousVisibleEntityIDs.count))
        for entity in visible {
            if !previousVisibleEntityIDs.contains(entity.id)
                || changedAtWorldRevision[entity.id, default: 0] > baseWorldRevision {
                changes.append(.upsert(entity))
            }
        }
        for entityID in previousVisibleEntityIDs where !visibleIDs.contains(entityID) {
            changes.append(.remove(entityID))
        }
        changes.sort { $0.id.uuidString < $1.id.uuidString }

        let total = changes.count
        guard offset <= total else { throw GameRealtimeInterestError.invalidQuery }
        let end = min(total, offset + min(limit, configuration.maximumPageEntities))
        var page: [GameRealtimeInterestChange] = []
        page.reserveCapacity(end - offset)
        var pageBytes = 0
        for change in changes[offset..<end] {
            let (nextBytes, overflow) = pageBytes.addingReportingOverflow(change.payloadBytes)
            guard !overflow, nextBytes <= configuration.maximumPageBytes else {
                if page.isEmpty { throw GameRealtimeInterestError.capacityReached }
                break
            }
            page.append(change)
            pageBytes = nextBytes
        }
        let nextOffset = offset + page.count < total ? offset + page.count : nil
        return GameRealtimeInterestDeltaPage(
            baseWorldRevision: baseWorldRevision,
            worldRevision: revision,
            totalChanges: total,
            changes: page,
            nextOffset: nextOffset
        )
    }

    public func metrics() -> GameRealtimeInterestMetrics {
        GameRealtimeInterestMetrics(entityCount: entities.count, retainedStateBytes: retainedStateBytes, worldRevision: revision)
    }

    private func cell(for position: GameRealtimePosition) -> Cell {
        Cell(x: floorDivision(position.x), y: floorDivision(position.y))
    }

    private func visibleEntities(around center: GameRealtimePosition, radiusCells: Int) throws -> [GameRealtimeSpatialEntity] {
        let centerCell = cell(for: center)
        let radius = Int64(radiusCells)
        var visible: [GameRealtimeSpatialEntity] = []
        for y in (centerCell.y - radius)...(centerCell.y + radius) {
            for x in (centerCell.x - radius)...(centerCell.x + radius) {
                guard let ids = entitiesByCell[Cell(x: x, y: y)] else { continue }
                guard ids.count <= configuration.maximumQueryCandidates - visible.count else {
                    throw GameRealtimeInterestError.capacityReached
                }
                for id in ids {
                    if let entity = entities[id] { visible.append(entity) }
                }
            }
        }
        visible.sort { $0.id.uuidString < $1.id.uuidString }
        return visible
    }

    private func floorDivision(_ coordinate: Int32) -> Int64 {
        let value = Int64(coordinate)
        let divisor = Int64(configuration.cellSize)
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }
}

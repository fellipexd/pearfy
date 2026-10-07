import Foundation
import PearfyData
import PearfyGameServer

public enum PostgresGameWorldError: Error, Sendable, Equatable {
    case invalidConfiguration
    case zoneLeaseHeld
    case zoneLeaseExpired
    case zoneRetired
    case zoneCapacityReached
    case zoneNotEmpty
    case entityAlreadyExists
    case entityNotFound
    case staleEntityEpoch
    case entityCapacityReached
    case entityStateTooLarge
    case invalidStoredRecord
}

public struct PostgresGameWorldConfiguration: Sendable, Equatable {
    public let maximumActiveZones: Int
    public let maximumEntitiesPerZone: Int
    public let maximumEntityStateBytes: Int
    public let maximumStateBytesPerZone: Int

    public static let standard = PostgresGameWorldConfiguration(
        maximumActiveZones: 256,
        maximumEntitiesPerZone: 100_000,
        maximumEntityStateBytes: 65_536,
        maximumStateBytesPerZone: 67_108_864,
        standard: ()
    )

    public init(maximumActiveZones: Int = 256, maximumEntitiesPerZone: Int = 100_000,
                maximumEntityStateBytes: Int = 65_536, maximumStateBytesPerZone: Int = 67_108_864) throws {
        guard (1...100_000).contains(maximumActiveZones), (1...10_000_000).contains(maximumEntitiesPerZone),
              (1...1_048_576).contains(maximumEntityStateBytes), (1...1_073_741_824).contains(maximumStateBytesPerZone),
              maximumEntityStateBytes <= maximumStateBytesPerZone else {
            throw PostgresGameWorldError.invalidConfiguration
        }
        self.maximumActiveZones = maximumActiveZones
        self.maximumEntitiesPerZone = maximumEntitiesPerZone
        self.maximumEntityStateBytes = maximumEntityStateBytes
        self.maximumStateBytesPerZone = maximumStateBytesPerZone
    }

    private init(maximumActiveZones: Int, maximumEntitiesPerZone: Int, maximumEntityStateBytes: Int, maximumStateBytesPerZone: Int, standard: Void) {
        self.maximumActiveZones = maximumActiveZones
        self.maximumEntitiesPerZone = maximumEntitiesPerZone
        self.maximumEntityStateBytes = maximumEntityStateBytes
        self.maximumStateBytesPerZone = maximumStateBytesPerZone
    }
}

/// Process authority token for one world zone. Epochs increase on every takeover;
/// all state writes validate the live owner and epoch inside their SQL transaction.
public struct PostgresGameZoneLease: Sendable, Equatable {
    public let zoneID: UUID
    public let ownerID: UUID
    public let fencingEpoch: UInt64
    public let durationMilliseconds: Int64

    fileprivate init(zoneID: UUID, ownerID: UUID, fencingEpoch: UInt64, durationMilliseconds: Int64) {
        self.zoneID = zoneID
        self.ownerID = ownerID
        self.fencingEpoch = fencingEpoch
        self.durationMilliseconds = durationMilliseconds
    }
}

public typealias PostgresGameWorldEntity = GameWorldEntity

/// PostgreSQL-backed zone authority and bounded entity-state store. Mutations serialize
/// per zone in the control/persistence plane; callers must keep this adapter off the tick.
public actor PostgresGameWorldLeaseStore {
    private let database: any SQLDatabase
    private let configuration: PostgresGameWorldConfiguration
    private let zoneTable: String
    private let entityTable: String
    private let rawPrefix: String

    public init(database: any SQLDatabase, configuration: PostgresGameWorldConfiguration = .standard,
                tablePrefix: String = "pearfy_game_world") throws {
        let names = try Self.tableNames(prefix: tablePrefix)
        self.database = database
        self.configuration = configuration
        self.zoneTable = names.zones
        self.entityTable = names.entities
        self.rawPrefix = names.rawPrefix
    }

    public static func migration(tablePrefix: String = "pearfy_game_world") throws -> SQLMigration {
        let names = try tableNames(prefix: tablePrefix)
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS \(names.zones) (
                zone_id UUID PRIMARY KEY,
                owner_id UUID NOT NULL,
                fencing_epoch BIGINT NOT NULL CHECK (fencing_epoch > 0),
                expires_at TIMESTAMPTZ NOT NULL,
                retired_at TIMESTAMPTZ
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS \(names.entities) (
                entity_id UUID PRIMARY KEY,
                zone_id UUID NOT NULL REFERENCES \(names.zones) (zone_id),
                owner_id UUID,
                fencing_epoch BIGINT NOT NULL CHECK (fencing_epoch > 0),
                state BYTEA NOT NULL,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
            )
            """,
            "CREATE INDEX IF NOT EXISTS \"\(names.rawPrefix)_zone_entities_idx\" ON \(names.entities) (zone_id, entity_id)"
        ]
        return SQLMigration(id: "pearfy-game-world-v1-\(names.rawPrefix.lowercased())", up: SQLQuery(unsafeSQL: statements.joined(separator: ";\n")))
    }

    /// Acquires a new zone or renews the same owner's lease. A different live owner is
    /// rejected; after expiry, takeover advances the fencing epoch atomically.
    public func acquireLease(zoneID: UUID, ownerID: UUID = UUID(), durationMilliseconds: Int64 = 15_000) async throws -> PostgresGameZoneLease {
        guard (1_000...300_000).contains(durationMilliseconds) else { throw PostgresGameWorldError.invalidConfiguration }
        return try await database.withTransaction { transaction in
            try await self.lockCatalog(transaction)
            try await self.lockZone(zoneID, transaction)
            let row = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "SELECT json_build_object('owner', owner_id::TEXT, 'epoch', fencing_epoch, 'active', expires_at > clock_timestamp(), 'retired', retired_at IS NOT NULL)::TEXT AS value FROM \(self.zoneTable) WHERE zone_id = $1",
                parameters: [.uuid(zoneID)]
            ), column: "value").first
            guard let row else {
                let activeZoneRows = try await transaction.queryStrings(SQLQuery(
                    unsafeSQL: "SELECT COUNT(*)::TEXT AS value FROM \(self.zoneTable) WHERE retired_at IS NULL",
                    parameters: []
                ), column: "value")
                guard let activeZones = activeZoneRows.first.flatMap(Int.init) else { throw PostgresGameWorldError.invalidStoredRecord }
                guard activeZones < self.configuration.maximumActiveZones else { throw PostgresGameWorldError.zoneCapacityReached }
                try await transaction.execute(SQLQuery(
                    unsafeSQL: "INSERT INTO \(self.zoneTable) (zone_id, owner_id, fencing_epoch, expires_at) VALUES ($1, $2, 1, clock_timestamp() + ($3::DOUBLE PRECISION * INTERVAL '1 millisecond'))",
                    parameters: [.uuid(zoneID), .uuid(ownerID), .decimal(Double(durationMilliseconds))]
                ))
                return PostgresGameZoneLease(zoneID: zoneID, ownerID: ownerID, fencingEpoch: 1, durationMilliseconds: durationMilliseconds)
            }
            let stored = try Self.decode(LeaseDocument.self, from: row)
            guard !stored.retired else { throw PostgresGameWorldError.zoneRetired }
            if stored.active && stored.owner != ownerID { throw PostgresGameWorldError.zoneLeaseHeld }
            let epoch = stored.active ? stored.epoch : stored.epoch &+ 1
            guard epoch > 0, epoch <= UInt64(Int64.max) else { throw PostgresGameWorldError.invalidStoredRecord }
            try await transaction.execute(SQLQuery(
                unsafeSQL: "UPDATE \(self.zoneTable) SET owner_id = $2, fencing_epoch = $3, expires_at = clock_timestamp() + ($4::DOUBLE PRECISION * INTERVAL '1 millisecond') WHERE zone_id = $1",
                parameters: [.uuid(zoneID), .uuid(ownerID), .integer(Int64(epoch)), .decimal(Double(durationMilliseconds))]
            ))
            return PostgresGameZoneLease(zoneID: zoneID, ownerID: ownerID, fencingEpoch: epoch, durationMilliseconds: durationMilliseconds)
        }
    }

    @discardableResult
    public func renewLease(_ lease: PostgresGameZoneLease, durationMilliseconds: Int64? = nil) async throws -> Bool {
        let duration = durationMilliseconds ?? lease.durationMilliseconds
        guard (1_000...300_000).contains(duration) else { throw PostgresGameWorldError.invalidConfiguration }
        return try await database.withTransaction { transaction in
            try await self.lockZone(lease.zoneID, transaction)
            try await self.verifyLease(lease, transaction)
            let rows = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "UPDATE \(self.zoneTable) SET expires_at = clock_timestamp() + ($4::DOUBLE PRECISION * INTERVAL '1 millisecond') WHERE zone_id = $1 AND owner_id = $2 AND fencing_epoch = $3 AND expires_at > clock_timestamp() AND retired_at IS NULL RETURNING zone_id::TEXT AS value",
                parameters: [.uuid(lease.zoneID), .uuid(lease.ownerID), .integer(Int64(lease.fencingEpoch)), .decimal(Double(duration))]
            ), column: "value")
            return !rows.isEmpty
        }
    }

    @discardableResult
    public func releaseLease(_ lease: PostgresGameZoneLease) async throws -> Bool {
        try await database.withTransaction { transaction in
            try await self.lockZone(lease.zoneID, transaction)
            let rows = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "UPDATE \(self.zoneTable) SET expires_at = clock_timestamp() WHERE zone_id = $1 AND owner_id = $2 AND fencing_epoch = $3 AND expires_at > clock_timestamp() AND retired_at IS NULL RETURNING zone_id::TEXT AS value",
                parameters: [.uuid(lease.zoneID), .uuid(lease.ownerID), .integer(Int64(lease.fencingEpoch))]
            ), column: "value")
            return !rows.isEmpty
        }
    }

    /// Creates an entity if the active zone's count and byte budgets allow it.
    public func createEntity(_ lease: PostgresGameZoneLease, id: UUID = UUID(), ownerID: UUID? = nil, state: Data) async throws -> PostgresGameWorldEntity {
        guard state.count <= configuration.maximumEntityStateBytes else { throw PostgresGameWorldError.entityStateTooLarge }
        return try await database.withTransaction { transaction in
            try await self.lockZone(lease.zoneID, transaction)
            try await self.verifyLease(lease, transaction)
            let existing = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "SELECT entity_id::TEXT AS value FROM \(self.entityTable) WHERE entity_id = $1",
                parameters: [.uuid(id)]
            ), column: "value")
            guard existing.isEmpty else { throw PostgresGameWorldError.entityAlreadyExists }
            let usage = try await self.zoneUsage(lease.zoneID, transaction)
            guard usage.count < self.configuration.maximumEntitiesPerZone,
                  usage.bytes <= self.configuration.maximumStateBytesPerZone - state.count else {
                throw PostgresGameWorldError.entityCapacityReached
            }
            try await transaction.execute(SQLQuery(
                unsafeSQL: "INSERT INTO \(self.entityTable) (entity_id, zone_id, owner_id, fencing_epoch, state) VALUES ($1, $2, $3, 1, $4)",
                parameters: [.uuid(id), .uuid(lease.zoneID), ownerID.map(SQLValue.uuid) ?? .null, .bytes(state)]
            ))
            return PostgresGameWorldEntity(id: id, zoneID: lease.zoneID, ownerID: ownerID, fencingEpoch: 1, state: state)
        }
    }

    /// Replaces bounded state only if the caller has the current zone lease and entity epoch.
    public func updateEntity(_ lease: PostgresGameZoneLease, entityID: UUID, expectedEntityEpoch: UInt64, state: Data) async throws -> PostgresGameWorldEntity {
        guard state.count <= configuration.maximumEntityStateBytes else { throw PostgresGameWorldError.entityStateTooLarge }
        return try await database.withTransaction { transaction in
            try await self.lockZone(lease.zoneID, transaction)
            try await self.verifyLease(lease, transaction)
            let payloads = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "SELECT json_build_object('owner', owner_id::TEXT, 'epoch', fencing_epoch, 'bytes', octet_length(state))::TEXT AS value FROM \(self.entityTable) WHERE entity_id = $1 AND zone_id = $2 FOR UPDATE",
                parameters: [.uuid(entityID), .uuid(lease.zoneID)]
            ), column: "value")
            guard let payload = payloads.first else { throw PostgresGameWorldError.entityNotFound }
            let stored = try Self.decode(EntityMetadata.self, from: payload)
            guard stored.epoch == expectedEntityEpoch else { throw PostgresGameWorldError.staleEntityEpoch }
            let usage = try await self.zoneUsage(lease.zoneID, transaction)
            let bytesWithoutEntity = usage.bytes - stored.bytes
            guard bytesWithoutEntity <= self.configuration.maximumStateBytesPerZone - state.count else {
                throw PostgresGameWorldError.entityCapacityReached
            }
            try await transaction.execute(SQLQuery(
                unsafeSQL: "UPDATE \(self.entityTable) SET state = $3, updated_at = clock_timestamp() WHERE entity_id = $1 AND zone_id = $2",
                parameters: [.uuid(entityID), .uuid(lease.zoneID), .bytes(state)]
            ))
            return PostgresGameWorldEntity(id: entityID, zoneID: lease.zoneID, ownerID: stored.owner, fencingEpoch: stored.epoch, state: state)
        }
    }

    /// Removes an entity with optimistic entity fencing and active zone authority.
    @discardableResult
    public func removeEntity(_ lease: PostgresGameZoneLease, entityID: UUID, expectedEntityEpoch: UInt64) async throws -> Bool {
        try await database.withTransaction { transaction in
            try await self.lockZone(lease.zoneID, transaction)
            try await self.verifyLease(lease, transaction)
            let rows = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "DELETE FROM \(self.entityTable) WHERE entity_id = $1 AND zone_id = $2 AND fencing_epoch = $3 RETURNING entity_id::TEXT AS value",
                parameters: [.uuid(entityID), .uuid(lease.zoneID), .integer(Int64(expectedEntityEpoch))]
            ), column: "value")
            if rows.isEmpty {
                let exists = try await transaction.queryStrings(SQLQuery(
                    unsafeSQL: "SELECT entity_id::TEXT AS value FROM \(self.entityTable) WHERE entity_id = $1 AND zone_id = $2",
                    parameters: [.uuid(entityID), .uuid(lease.zoneID)]
                ), column: "value")
                if !exists.isEmpty { throw PostgresGameWorldError.staleEntityEpoch }
            }
            return !rows.isEmpty
        }
    }

    /// Atomically hands an entity between two live zones, requiring both fencing tokens.
    public func transferEntity(entityID: UUID, from source: PostgresGameZoneLease, to destination: PostgresGameZoneLease) async throws -> PostgresGameWorldEntity {
        guard source.zoneID != destination.zoneID else { throw PostgresGameWorldError.invalidConfiguration }
        return try await database.withTransaction { transaction in
            for zoneID in [source.zoneID, destination.zoneID].sorted(by: { $0.uuidString < $1.uuidString }) {
                try await self.lockZone(zoneID, transaction)
            }
            try await self.verifyLease(source, transaction)
            try await self.verifyLease(destination, transaction)
            let documents = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "SELECT json_build_object('owner', owner_id::TEXT, 'epoch', fencing_epoch, 'state', encode(state, 'base64'))::TEXT AS value FROM \(self.entityTable) WHERE entity_id = $1 AND zone_id = $2 FOR UPDATE",
                parameters: [.uuid(entityID), .uuid(source.zoneID)]
            ), column: "value")
            guard let document = documents.first else { throw PostgresGameWorldError.entityNotFound }
            let entity = try Self.decode(EntityDocument.self, from: document)
            guard entity.epoch < UInt64(Int64.max), let state = Data(base64Encoded: entity.state) else { throw PostgresGameWorldError.invalidStoredRecord }
            guard state.count <= self.configuration.maximumEntityStateBytes else { throw PostgresGameWorldError.entityStateTooLarge }
            let usage = try await self.zoneUsage(destination.zoneID, transaction)
            guard usage.count < self.configuration.maximumEntitiesPerZone,
                  usage.bytes <= self.configuration.maximumStateBytesPerZone - state.count else {
                throw PostgresGameWorldError.entityCapacityReached
            }
            let nextEpoch = entity.epoch + 1
            try await transaction.execute(SQLQuery(
                unsafeSQL: "UPDATE \(self.entityTable) SET zone_id = $2, fencing_epoch = $3, updated_at = clock_timestamp() WHERE entity_id = $1 AND zone_id = $4",
                parameters: [.uuid(entityID), .uuid(destination.zoneID), .integer(Int64(nextEpoch)), .uuid(source.zoneID)]
            ))
            return PostgresGameWorldEntity(id: entityID, zoneID: destination.zoneID, ownerID: entity.owner, fencingEpoch: nextEpoch, state: state)
        }
    }

    /// Returns a bounded, deterministic page after validating the current zone lease.
    public func entities(in lease: PostgresGameZoneLease, offset: Int = 0, limit: Int = 100) async throws -> (total: Int, entities: [PostgresGameWorldEntity]) {
        guard offset >= 0, (1...500).contains(limit) else { throw PostgresGameWorldError.invalidConfiguration }
        return try await database.withTransaction { transaction in
            try await self.lockZone(lease.zoneID, transaction)
            try await self.verifyLease(lease, transaction)
            let totalText = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "SELECT COUNT(*)::TEXT AS value FROM \(self.entityTable) WHERE zone_id = $1",
                parameters: [.uuid(lease.zoneID)]
            ), column: "value").first
            guard let total = totalText.flatMap(Int.init) else { throw PostgresGameWorldError.invalidStoredRecord }
            let rows = try await transaction.queryStrings(SQLQuery(
                unsafeSQL: "SELECT json_build_object('id', entity_id::TEXT, 'zone', zone_id::TEXT, 'owner', owner_id::TEXT, 'epoch', fencing_epoch, 'state', encode(state, 'base64'))::TEXT AS value FROM \(self.entityTable) WHERE zone_id = $1 ORDER BY entity_id LIMIT $2 OFFSET $3",
                parameters: [.uuid(lease.zoneID), .integer(Int64(limit)), .integer(Int64(offset))]
            ), column: "value")
            let entities = try rows.map { row -> PostgresGameWorldEntity in
                let value = try Self.decode(EntityPageDocument.self, from: row)
                guard let state = Data(base64Encoded: value.state) else { throw PostgresGameWorldError.invalidStoredRecord }
                return PostgresGameWorldEntity(id: value.id, zoneID: value.zone, ownerID: value.owner, fencingEpoch: value.epoch, state: state)
            }
            return (total, entities)
        }
    }

    /// Retires an empty zone and frees one active-zone slot without deleting its epoch history.
    public func retireZone(_ lease: PostgresGameZoneLease) async throws {
        try await database.withTransaction { transaction in
            try await self.lockCatalog(transaction)
            try await self.lockZone(lease.zoneID, transaction)
            try await self.verifyLease(lease, transaction)
            let count = try await self.zoneUsage(lease.zoneID, transaction).count
            guard count == 0 else { throw PostgresGameWorldError.zoneNotEmpty }
            try await transaction.execute(SQLQuery(
                unsafeSQL: "UPDATE \(self.zoneTable) SET retired_at = clock_timestamp(), expires_at = clock_timestamp() WHERE zone_id = $1 AND owner_id = $2 AND fencing_epoch = $3",
                parameters: [.uuid(lease.zoneID), .uuid(lease.ownerID), .integer(Int64(lease.fencingEpoch))]
            ))
        }
    }

    private func verifyLease(_ lease: PostgresGameZoneLease, _ transaction: any SQLTransaction) async throws {
        guard lease.fencingEpoch > 0, lease.fencingEpoch <= UInt64(Int64.max) else { throw PostgresGameWorldError.zoneLeaseExpired }
        let rows = try await transaction.queryStrings(SQLQuery(
            unsafeSQL: "SELECT (owner_id = $2 AND fencing_epoch = $3 AND expires_at > clock_timestamp() AND retired_at IS NULL)::TEXT AS value FROM \(zoneTable) WHERE zone_id = $1",
            parameters: [.uuid(lease.zoneID), .uuid(lease.ownerID), .integer(Int64(lease.fencingEpoch))]
        ), column: "value")
        guard rows.first == "true" else { throw PostgresGameWorldError.zoneLeaseExpired }
    }

    private func zoneUsage(_ zoneID: UUID, _ transaction: any SQLTransaction) async throws -> (count: Int, bytes: Int) {
        let row = try await transaction.queryStrings(SQLQuery(
            unsafeSQL: "SELECT json_build_object('count', COUNT(*), 'bytes', COALESCE(SUM(octet_length(state)), 0))::TEXT AS value FROM \(entityTable) WHERE zone_id = $1",
            parameters: [.uuid(zoneID)]
        ), column: "value").first
        guard let row else { throw PostgresGameWorldError.invalidStoredRecord }
        let usage = try Self.decode(UsageDocument.self, from: row)
        return (usage.count, usage.bytes)
    }

    private func lockCatalog(_ transaction: any SQLTransaction) async throws {
        try await transaction.execute(SQLQuery(unsafeSQL: "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", parameters: [.text("pearfy-game-world-catalog:\(rawPrefix)")] ))
    }

    private func lockZone(_ zoneID: UUID, _ transaction: any SQLTransaction) async throws {
        try await transaction.execute(SQLQuery(unsafeSQL: "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", parameters: [.text("pearfy-game-world-zone:\(rawPrefix):\(zoneID.uuidString.lowercased())")] ))
    }

    private struct LeaseDocument: Decodable { let owner: UUID; let epoch: UInt64; let active: Bool; let retired: Bool }
    private struct EntityMetadata: Decodable { let owner: UUID?; let epoch: UInt64; let bytes: Int }
    private struct EntityDocument: Decodable { let owner: UUID?; let epoch: UInt64; let state: String }
    private struct EntityPageDocument: Decodable { let id: UUID; let zone: UUID; let owner: UUID?; let epoch: UInt64; let state: String }
    private struct UsageDocument: Decodable { let count: Int; let bytes: Int }

    private static func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        guard let data = value.data(using: .utf8) else { throw PostgresGameWorldError.invalidStoredRecord }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw PostgresGameWorldError.invalidStoredRecord }
    }

    private struct TableNames { let zones: String; let entities: String; let rawPrefix: String }

    private static func tableNames(prefix: String) throws -> TableNames {
        guard !prefix.isEmpty, prefix.utf8.count <= 40, prefix.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95
        }) else { throw PostgresGameWorldError.invalidConfiguration }
        return TableNames(
            zones: try SQLIdentifier("\(prefix)_zones").description,
            entities: try SQLIdentifier("\(prefix)_entities").description,
            rawPrefix: prefix
        )
    }
}

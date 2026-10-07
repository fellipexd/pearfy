import Foundation
import Crypto
import NIOCore
import NIOPosix
@preconcurrency import NIOSSL
import PearfyGameServer
@preconcurrency import RediStack

public struct RedisGameStateRecoveryConfiguration: Sendable {
    public let host: String
    public let port: Int
    public let username: String?
    public let password: String?
    public let database: Int
    public let keyPrefix: String
    public let tlsEnabled: Bool
    public let serverName: String
    public let maximumConnections: Int
    public let maximumEventsPerSession: Int
    public let maximumRecordBytes: Int
    public let maximumRecoveryBytes: Int
    public let connectionRetryTimeoutMilliseconds: Int64

    public init(host: String = "127.0.0.1", port: Int = 6379, username: String? = nil, password: String? = nil,
                database: Int = 0, keyPrefix: String = "pearfy:game-recovery", maximumConnections: Int = 4,
                maximumEventsPerSession: Int = 100_000, maximumRecordBytes: Int = 33_554_432,
                connectionRetryTimeoutMilliseconds: Int64 = 5_000, tlsEnabled: Bool = false,
                serverName: String? = nil, maximumRecoveryBytes: Int = 67_108_864) throws {
        let validPrefix = !keyPrefix.isEmpty && keyPrefix.utf8.count <= 96 && keyPrefix.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 || $0 == 58
        }
        let tlsServerName = serverName ?? host
        let isLoopback = host == "localhost" || host == "::1" || host.hasPrefix("127.")
        guard !host.isEmpty, (1...65_535).contains(port), database >= 0, validPrefix,
              (1...128).contains(maximumConnections), (1...1_000_000).contains(maximumEventsPerSession),
              (1...33_554_432).contains(maximumRecordBytes), (1...1_073_741_824).contains(maximumRecoveryBytes),
              connectionRetryTimeoutMilliseconds > 0, username?.isEmpty != true, password?.isEmpty != true,
              username == nil || password != nil, (!isLoopback ? tlsEnabled : true),
              !tlsServerName.isEmpty, tlsServerName.utf8.count <= 253,
              tlsServerName.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 58
              }) else { throw RedisGameStateRecoveryError.invalidConfiguration }
        self.host = host; self.port = port; self.username = username; self.password = password
        self.database = database; self.keyPrefix = keyPrefix; self.maximumConnections = maximumConnections
        self.tlsEnabled = tlsEnabled; self.serverName = tlsServerName
        self.maximumEventsPerSession = maximumEventsPerSession; self.maximumRecordBytes = maximumRecordBytes
        self.maximumRecoveryBytes = maximumRecoveryBytes
        self.connectionRetryTimeoutMilliseconds = connectionRetryTimeoutMilliseconds
    }
}

public enum RedisGameStateRecoveryError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidConfiguration, notStarted, invalidResponse, staleEpoch, leaseHeld, leaseExpired, sequenceConflict, staleCheckpoint, journalCapacityReached, journalUnavailable, commandCommitInProgress
    case invalidTickBatch, tickBatchLimitExceeded, tickSequenceConflict(expected: UInt64, actual: UInt64)
    case tickQueueCapacityReached, tickBatchAlreadyQueued
    case staleProjection, projectionRevisionConflict
    case unsupportedSnapshotVersion, recordTooLarge(maximumBytes: Int), recoveryLimitExceeded, shutdown(String)
    public var description: String {
        switch self {
        case .invalidConfiguration: "invalid Redis game recovery configuration"
        case .notStarted: "Redis game recovery store has not started"
        case .invalidResponse: "unexpected Redis game recovery response"
        case .staleEpoch: "game session recovery epoch is stale"
        case .leaseHeld: "game session already has an active recovery lease"
        case .leaseExpired: "game session recovery lease is absent or expired"
        case .sequenceConflict: "game session recovery event sequence conflicts with the journal"
        case .staleCheckpoint: "game session checkpoint would replace a newer or conflicting checkpoint"
        case .journalCapacityReached: "game state journal reached its event limit before a checkpoint"
        case .journalUnavailable: "game state journal is unavailable after an uncommitted write"
        case .commandCommitInProgress: "another durable game command or checkpoint is still in progress"
        case .invalidTickBatch: "authoritative game tick batch is invalid"
        case .tickBatchLimitExceeded: "authoritative game tick batch exceeds its configured bounds"
        case .tickSequenceConflict(let expected, let actual): "authoritative game tick sequence expected \(expected), received \(actual)"
        case .tickQueueCapacityReached: "authoritative game tick writer queue reached its configured limit"
        case .tickBatchAlreadyQueued: "authoritative game tick batch is already waiting in the writer queue"
        case .staleProjection: "game state projection revision is older than the retained revision"
        case .projectionRevisionConflict: "game state projection changed without advancing its revision"
        case .unsupportedSnapshotVersion: "unsupported game state recovery snapshot version"
        case .recordTooLarge(let maximumBytes): "recovery record exceeds \(maximumBytes) bytes"
        case .recoveryLimitExceeded: "recovery replay exceeds its configured memory bound"
        case .shutdown(let reason): "Redis game recovery shutdown failed: \(reason)"
        }
    }
}

/// Fencing token for one process's temporary authority over a recoverable session.
/// The epoch increases whenever a new owner acquires an expired or released lease.
public struct GameStateSessionLease: Sendable, Equatable {
    public let sessionID: UUID
    public let ownerID: UUID
    public let epoch: UInt64
    public let durationMilliseconds: Int64

    init(sessionID: UUID, ownerID: UUID, epoch: UInt64, durationMilliseconds: Int64) {
        self.sessionID = sessionID
        self.ownerID = ownerID
        self.epoch = epoch
        self.durationMilliseconds = durationMilliseconds
    }
}

private struct RedisGameStateSnapshotEnvelope: Codable, Sendable {
    let schemaVersion: UInt16
    let records: [GameServerStateRecord]
}

private struct RedisGameStateEventEnvelope: Codable, Sendable {
    let schemaVersion: UInt16
    let record: GameServerStateRecord
}

struct RedisGameSnapshotManifest: Sendable, Equatable {
    static let marker = "pearfy-chunked-v1:"
    static let chunkByteLimit = 256 * 1_024
    static let maximumChunkCount = 256

    let generation: String
    let digest: String
    let chunkCount: Int
    let encodedByteCount: Int
    let rawByteCount: Int

    var encodedValue: String {
        "\(Self.marker)\(generation):\(digest):\(chunkCount):\(encodedByteCount):\(rawByteCount)"
    }

    static func make(for data: Data) -> (manifest: RedisGameSnapshotManifest, chunks: [String]) {
        let encoded = data.base64EncodedString()
        let bytes = Array(encoded.utf8)
        let chunks = stride(from: 0, to: bytes.count, by: chunkByteLimit).map { start in
            String(decoding: bytes[start..<min(bytes.count, start + chunkByteLimit)], as: UTF8.self)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let generation = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return (RedisGameSnapshotManifest(generation: generation, digest: digest, chunkCount: chunks.count,
                                         encodedByteCount: bytes.count, rawByteCount: data.count), chunks)
    }

    static func parse(_ value: String, maximumRecordBytes: Int, maximumRecoveryBytes: Int) throws -> RedisGameSnapshotManifest? {
        guard value.hasPrefix(marker) else { return nil }
        let fields = value.dropFirst(marker.count).split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 5,
              fields[0].count == 32,
              fields[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              fields[1].count == 64,
              fields[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let count = Int(fields[2]), let encodedCount = Int(fields[3]), let rawCount = Int(fields[4]),
              (1...maximumChunkCount).contains(count), encodedCount > 0,
              encodedCount <= maximumRecordBytes * 2, rawCount > 0,
              rawCount <= maximumRecordBytes, rawCount <= maximumRecoveryBytes,
              count == (encodedCount + chunkByteLimit - 1) / chunkByteLimit,
              encodedCount > (count - 1) * chunkByteLimit,
              encodedCount <= count * chunkByteLimit else {
            throw RedisGameStateRecoveryError.invalidResponse
        }
        return RedisGameSnapshotManifest(generation: String(fields[0]), digest: String(fields[1]), chunkCount: count,
                                         encodedByteCount: encodedCount, rawByteCount: rawCount)
    }

    func decode(chunks: [String], maximumRecordBytes: Int, maximumRecoveryBytes: Int) throws -> Data {
        guard chunks.count == chunkCount else { throw RedisGameStateRecoveryError.invalidResponse }
        var encoded = String()
        encoded.reserveCapacity(encodedByteCount)
        for (index, chunk) in chunks.enumerated() {
            let expectedSize = index == chunkCount - 1
                ? encodedByteCount - index * Self.chunkByteLimit
                : Self.chunkByteLimit
            guard chunk.utf8.count == expectedSize else { throw RedisGameStateRecoveryError.invalidResponse }
            encoded.append(chunk)
        }
        guard encoded.utf8.count == encodedByteCount,
              let data = Data(base64Encoded: encoded), data.count == rawByteCount else {
            throw RedisGameStateRecoveryError.invalidResponse
        }
        guard data.count <= maximumRecordBytes else {
            throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: maximumRecordBytes)
        }
        guard data.count <= maximumRecoveryBytes else { throw RedisGameStateRecoveryError.recoveryLimitExceeded }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == self.digest else { throw RedisGameStateRecoveryError.invalidResponse }
        return data
    }
}

struct RedisGameRecoveryMetadata: Sendable, Equatable {
    let epoch: UInt64
    let latestSequence: UInt64
    let snapshotData: Data
}

func decodeRedisGameRecoveryMetadata(
    snapshotJSON: String?,
    epochText: String?,
    sequenceText: String?,
    streamLength: Int,
    maximumRecordBytes: Int,
    maximumRecoveryBytes: Int
) throws -> RedisGameRecoveryMetadata? {
    guard let snapshotJSON else {
        guard sequenceText == nil, streamLength == 0 else { throw RedisGameStateRecoveryError.invalidResponse }
        return nil
    }
    guard let epochText, let epoch = UInt64(epochText), epoch > 0,
          let sequenceText, let sequence = UInt64(sequenceText) else {
        throw RedisGameStateRecoveryError.invalidResponse
    }
    guard snapshotJSON.utf8.count <= maximumRecordBytes * 2 else {
        throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: maximumRecordBytes)
    }
    guard let snapshotData = Data(base64Encoded: snapshotJSON) else {
        throw RedisGameStateRecoveryError.invalidResponse
    }
    guard snapshotData.count <= maximumRecordBytes else {
        throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: maximumRecordBytes)
    }
    guard snapshotData.count <= maximumRecoveryBytes else {
        throw RedisGameStateRecoveryError.recoveryLimitExceeded
    }
    return RedisGameRecoveryMetadata(epoch: epoch, latestSequence: sequence, snapshotData: snapshotData)
}

/// Bridges manager updates to the journal and can hydrate a manager before it starts.
/// Appends and periodic checkpoints run on the manager's dedicated middleware worker.
public actor RedisGameServerStateMiddleware: GameServerStateRestoringMiddleware {
    private struct PendingEvent {
        let identity: String
        let event: GameStateEvent
        let record: GameServerStateRecord
    }
    private let store: any GameStateRecoveryStore
    private let sessionID: UUID
    private let epoch: UInt64
    private let checkpointEvery: Int
    private let checkpointIntervalMilliseconds: Int64?
    private let maximumRetainedStates: Int
    private let maximumSnapshotBytes: Int
    private var sequence: UInt64 = 0
    private var records: [String: GameServerStateRecord] = [:]
    private var order: [String] = []
    private var retainedPayloadBytes = 0
    private var pendingEvent: PendingEvent?
    private var lastPersistedIdentity: String?
    private var lastCheckpointAt: ContinuousClock.Instant?
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(store: any GameStateRecoveryStore, sessionID: UUID, epoch: UInt64,
                checkpointEvery: Int = 100, maximumRetainedStates: Int = 10_000,
                maximumEventsPerSession: Int = 100_000, maximumSnapshotBytes: Int = 16_777_216,
                checkpointIntervalMilliseconds: Int64? = 30_000) throws {
        guard epoch > 0, (1...10_000).contains(checkpointEvery), (1...100_000).contains(maximumRetainedStates),
              (1...1_000_000).contains(maximumEventsPerSession), checkpointEvery <= maximumEventsPerSession,
              (1_048_576...268_435_456).contains(maximumSnapshotBytes),
              checkpointIntervalMilliseconds.map({ (100...86_400_000).contains($0) }) ?? true else {
            throw RedisGameStateRecoveryError.invalidConfiguration
        }
        self.store = store; self.sessionID = sessionID; self.epoch = epoch
        self.checkpointEvery = checkpointEvery; self.maximumRetainedStates = maximumRetainedStates
        self.maximumSnapshotBytes = maximumSnapshotBytes
        self.checkpointIntervalMilliseconds = checkpointIntervalMilliseconds
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    public func restore() async throws -> [GameServerStateRecord] {
        guard let recovery = try await store.load(sessionID: sessionID) else { return [] }
        guard recovery.epoch == epoch else { throw RedisGameStateRecoveryError.staleEpoch }
        let snapshot = try decoder.decode(RedisGameStateSnapshotEnvelope.self, from: recovery.checkpoint.state)
        guard snapshot.schemaVersion == 1, snapshot.records.count <= maximumRetainedStates else {
            throw RedisGameStateRecoveryError.unsupportedSnapshotVersion
        }
        guard recovery.checkpoint.state.count <= maximumSnapshotBytes,
              snapshot.records.reduce(0, { $0 + $1.payload.count }) <= maximumSnapshotBytes else {
            throw RedisGameStateRecoveryError.recoveryLimitExceeded
        }
        records.removeAll(keepingCapacity: true); order.removeAll(keepingCapacity: true); retainedPayloadBytes = 0
        for record in snapshot.records { try upsert(record) }
        sequence = recovery.checkpoint.revision
        for event in recovery.events.sorted(by: { $0.sequence < $1.sequence }) {
            guard event.sequence == sequence &+ 1 else { throw RedisGameStateRecoveryError.invalidResponse }
            let envelope = try decoder.decode(RedisGameStateEventEnvelope.self, from: event.payload)
            guard envelope.schemaVersion == 1 else { throw RedisGameStateRecoveryError.unsupportedSnapshotVersion }
            try upsert(envelope.record); sequence = event.sequence
        }
        guard sequence == recovery.latestSequence else { throw RedisGameStateRecoveryError.invalidResponse }
        pendingEvent = nil; lastPersistedIdentity = nil; lastCheckpointAt = .now
        return order.compactMap { records[$0] }
    }

    public func restoreRecords() async throws -> [GameServerStateRecord] {
        try await restore()
    }

    public func persist(_ record: GameServerStateRecord) async throws {
        let identity = "\(record.id):\(record.revision)"
        if let previous = records[record.id] {
            guard record.revision >= previous.revision else { throw RedisGameStateRecoveryError.staleProjection }
            if record.revision == previous.revision {
                guard record.payload == previous.payload else { throw RedisGameStateRecoveryError.projectionRevisionConflict }
                if checkpointIsDue { try await saveCheckpoint() }
                return
            }
        }
        if pendingEvent == nil, lastPersistedIdentity == identity {
            if checkpointIsDue { try await saveCheckpoint() }
            return
        }
        if let pendingEvent, pendingEvent.identity != identity { throw RedisGameStateRecoveryError.journalUnavailable }
        if sequence == 0 {
            let empty = try encoder.encode(RedisGameStateSnapshotEnvelope(schemaVersion: 1, records: []))
            try await store.save(sessionID: sessionID, epoch: epoch, checkpoint: GameStateCheckpoint(revision: 0, state: empty, events: []))
            lastCheckpointAt = .now
        }
        if pendingEvent == nil {
            let nextSequence = sequence &+ 1
            let envelope = try encoder.encode(RedisGameStateEventEnvelope(schemaVersion: 1, record: record))
            let event = GameStateEvent(sequence: nextSequence, commandID: UUID(), playerID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)), payload: envelope, state: Data())
            pendingEvent = PendingEvent(identity: identity, event: event, record: record)
        }
        guard let pendingEvent else { throw RedisGameStateRecoveryError.invalidResponse }
        try await store.append(sessionID: sessionID, epoch: epoch, event: pendingEvent.event)
        sequence = pendingEvent.event.sequence
        try upsert(pendingEvent.record)
        self.pendingEvent = nil; lastPersistedIdentity = identity
        if checkpointIsDue { try await saveCheckpoint() }
    }

    public func flush() async throws {
        if pendingEvent != nil { throw RedisGameStateRecoveryError.journalUnavailable }
        if sequence > 0 { try await saveCheckpoint() }
    }

    private func saveCheckpoint() async throws {
        let snapshot = RedisGameStateSnapshotEnvelope(schemaVersion: 1, records: order.compactMap { records[$0] })
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumSnapshotBytes else { throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: maximumSnapshotBytes) }
        try await store.save(sessionID: sessionID, epoch: epoch, checkpoint: GameStateCheckpoint(revision: sequence, state: data, events: []))
        lastCheckpointAt = .now
    }

    private var checkpointIsDue: Bool {
        if sequence > 0, sequence % UInt64(checkpointEvery) == 0 { return true }
        guard let checkpointIntervalMilliseconds, let lastCheckpointAt else { return false }
        return ContinuousClock.now - lastCheckpointAt >= .milliseconds(checkpointIntervalMilliseconds)
    }

    private func upsert(_ record: GameServerStateRecord) throws {
        guard record.payload.count <= maximumSnapshotBytes else { throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: maximumSnapshotBytes) }
        if let previous = records[record.id] {
            guard record.revision >= previous.revision else { throw RedisGameStateRecoveryError.staleProjection }
            if record.revision == previous.revision, record.payload != previous.payload {
                throw RedisGameStateRecoveryError.projectionRevisionConflict
            }
        }
        if let previous = records.removeValue(forKey: record.id) { retainedPayloadBytes -= previous.payload.count }
        order.removeAll { $0 == record.id }
        while records.count >= maximumRetainedStates || retainedPayloadBytes > maximumSnapshotBytes - record.payload.count {
            guard let oldest = order.first, let removed = records.removeValue(forKey: oldest) else { break }
            order.removeFirst(); retainedPayloadBytes -= removed.payload.count
        }
        records[record.id] = record; order.append(record.id)
        retainedPayloadBytes += record.payload.count
    }
}

/// Optional Redis Streams journal. The Redis server's AOF/RDB/replication policy defines
/// actual crash durability; this adapter does not claim cross-failover zero-RPO semantics.
public actor RedisGameStateRecoveryStore: GameStateRecoveryStore {
    private static let acquireLeaseScript = #"""
    local owner = redis.call('GET', KEYS[1])
    if owner then
      if owner ~= ARGV[1] then return -1 end
      local activeEpoch = redis.call('GET', KEYS[3])
      if not activeEpoch then return -2 end
      redis.call('PEXPIRE', KEYS[1], ARGV[2])
      return tonumber(activeEpoch)
    end
    local epoch = redis.call('INCR', KEYS[2])
    redis.call('SET', KEYS[1], ARGV[1], 'PX', ARGV[2])
    redis.call('SET', KEYS[3], epoch)
    return epoch
    """#
    private static let renewLeaseScript = #"""
    if redis.call('GET', KEYS[1]) ~= ARGV[1] or redis.call('GET', KEYS[2]) ~= ARGV[2] then return 0 end
    return redis.call('PEXPIRE', KEYS[1], ARGV[3])
    """#
    private static let releaseLeaseScript = #"""
    if redis.call('GET', KEYS[1]) ~= ARGV[1] or redis.call('GET', KEYS[2]) ~= ARGV[2] then return 0 end
    return redis.call('DEL', KEYS[1])
    """#
    private static let appendScript = """
    if not redis.call('GET', KEYS[7]) then return -4 end
    if redis.call('GET', KEYS[8]) ~= ARGV[1] then return -1 end
    local current = redis.call('GET', KEYS[2])
    if not current or current ~= ARGV[1] then return -1 end
    local last = tonumber(redis.call('GET', KEYS[3]) or '0')
    local requested = tonumber(ARGV[4])
    if requested == last and redis.call('GET', KEYS[4]) == ARGV[3] then return 1 end
    if requested ~= last + 1 then return -2 end
    local checkpoint = tonumber(redis.call('GET', KEYS[6]) or '0')
    if last - checkpoint >= tonumber(ARGV[2]) then return -3 end
    local id = redis.call('XADD', KEYS[1], 'MAXLEN', ARGV[2], '*', 'entry', ARGV[3])
    redis.call('SET', KEYS[3], ARGV[4])
    redis.call('SET', KEYS[4], ARGV[3])
    redis.call('SET', KEYS[5], id)
    return 1
    """
    private static let saveScript = """
    if not redis.call('GET', KEYS[7]) then return -4 end
    if redis.call('GET', KEYS[8]) ~= ARGV[1] then return -1 end
    local current = redis.call('GET', KEYS[2])
    if not current or current ~= ARGV[1] then return -1 end
    local sequence = redis.call('GET', KEYS[3])
    if not sequence then redis.call('SET', KEYS[3], '0'); sequence = '0' end
    local latest = tonumber(sequence)
    if tonumber(ARGV[2]) > latest then return -2 end
    local savedRevision = tonumber(redis.call('GET', KEYS[6]) or '-1')
    local requestedRevision = tonumber(ARGV[2])
    if requestedRevision < savedRevision then return -3 end
    local chunkCount = tonumber(ARGV[4])
    if #KEYS ~= 8 + chunkCount then return -5 end
    local newGeneration, newDigest, manifestChunkCount, encodedByteCount, rawByteCount =
      string.match(ARGV[3], '^pearfy%-chunked%-v1:([0-9a-f]+):([0-9a-f]+):(%d+):(%d+):(%d+)$')
    if chunkCount > 0 and (not newGeneration or tonumber(manifestChunkCount) ~= chunkCount or tonumber(encodedByteCount) ~= tonumber(ARGV[5])) then return -5 end
    local chunkByteCount = 0
    for index = 1, chunkCount do
      local chunkKey = KEYS[8 + index]
      if redis.call('EXISTS', chunkKey) ~= 1 then return -5 end
      chunkByteCount = chunkByteCount + redis.call('STRLEN', chunkKey)
    end
    if chunkCount > 0 and chunkByteCount ~= tonumber(ARGV[5]) then return -5 end
    if requestedRevision == savedRevision then
      if redis.call('GET', KEYS[1]) == ARGV[3] then
        for index = 1, chunkCount do redis.call('PERSIST', KEYS[8 + index]) end
        return 1
      end
      local oldGeneration, oldDigest, oldCount, oldEncodedBytes, oldRawBytes =
        string.match(redis.call('GET', KEYS[1]) or '', '^pearfy%-chunked%-v1:([0-9a-f]+):([0-9a-f]+):(%d+):(%d+):(%d+)$')
      if oldDigest and oldDigest == newDigest and oldEncodedBytes == encodedByteCount and oldRawBytes == rawByteCount then
        for index = 1, chunkCount do redis.call('DEL', KEYS[8 + index]) end
        return 1
      end
      return -3
    end
    local previous = redis.call('GET', KEYS[1])
    redis.call('SET', KEYS[1], ARGV[3])
    redis.call('SET', KEYS[6], ARGV[2])
    for index = 1, chunkCount do redis.call('PERSIST', KEYS[8 + index]) end
    if previous then
      local oldGeneration, oldDigest, oldCount = string.match(previous, '^pearfy%-chunked%-v1:([0-9a-f]+):([0-9a-f]+):(%d+):%d+:%d+$')
      if oldGeneration and oldCount and oldGeneration ~= newGeneration then
        for index = 1, tonumber(oldCount) do
          redis.call('DEL', KEYS[1] .. ':chunk:' .. oldGeneration .. ':' .. index)
        end
      end
    end
    if tonumber(ARGV[2]) == latest and latest > 0 then
      local id = redis.call('GET', KEYS[4])
      -- The checkpoint includes the event at `id`; remove that covered entry.
      -- MINID trimming is inclusive, so trimming at `id` would leave one covered
      -- event and make a full, valid post-checkpoint journal exceed the scan bound.
      if id then redis.call('XDEL', KEYS[5], id) end
    end
    return 1
    """

    private let configuration: RedisGameStateRecoveryConfiguration
    private var group: MultiThreadedEventLoopGroup?
    private var pool: RedisConnectionPool?
    private var starting = false
    private var stopping = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<String?, Never>] = []
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(configuration: RedisGameStateRecoveryConfiguration) {
        self.configuration = configuration
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    public func start() async throws {
        guard pool == nil else { return }
        guard !starting, !stopping else { throw RedisGameStateRecoveryError.invalidConfiguration }
        starting = true
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var candidate: RedisConnectionPool?
        do {
            let address = try SocketAddress.makeAddressResolvingHost(configuration.host, port: configuration.port)
            let factory = RedisConnectionPool.ConnectionFactoryConfiguration(
                connectionInitialDatabase: configuration.database,
                connectionUsername: configuration.username,
                connectionPassword: configuration.password,
                tcpClient: configuration.tlsEnabled ? Self.tlsClient(group: eventLoopGroup, serverName: configuration.serverName) : nil
            )
            let poolConfiguration = RedisConnectionPool.Configuration(
                initialServerConnectionAddresses: [address],
                maximumConnectionCount: .maximumActiveConnections(configuration.maximumConnections),
                connectionFactoryConfiguration: factory,
                minimumConnectionCount: 1,
                connectionRetryTimeout: .milliseconds(configuration.connectionRetryTimeoutMilliseconds)
            )
            let connectionPool = RedisConnectionPool(configuration: poolConfiguration, boundEventLoop: eventLoopGroup.next())
            candidate = connectionPool; connectionPool.activate(); _ = try await connectionPool.ping().get()
            self.group = eventLoopGroup; self.pool = connectionPool; starting = false
            finishStart()
        } catch {
            starting = false
            if let candidate { try? await Self.close(candidate) }
            try? await eventLoopGroup.shutdownGracefully()
            finishStart()
            throw error
        }
    }

    public func stop() async throws {
        if starting {
            await withCheckedContinuation { startWaiters.append($0) }
            try await stop()
            return
        }
        if stopping {
            let failure: String? = await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
            if let failure {
                throw RedisGameStateRecoveryError.shutdown(failure)
            }
            return
        }
        guard let group else { return }
        stopping = true
        let pool = self.pool
        self.group = nil
        self.pool = nil
        var failure: String?
        if let pool { do { try await Self.close(pool) } catch { failure = String(describing: error) } }
        do { try await group.shutdownGracefully() }
        catch { failure = [failure, String(describing: error)].compactMap { $0 }.joined(separator: "; ") }
        stopping = false
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0.resume(returning: failure) }
        if let failure { throw RedisGameStateRecoveryError.shutdown(failure) }
    }

    /// Acquires exclusive session authority. Use a fresh owner ID per process lifetime;
    /// a competing owner is rejected until the current lease expires or is released.
    public func acquireLease(sessionID: UUID, ownerID: UUID = UUID(), durationMilliseconds: Int64 = 15_000) async throws -> GameStateSessionLease {
        guard (1_000...300_000).contains(durationMilliseconds) else { throw RedisGameStateRecoveryError.invalidConfiguration }
        let response = try await activePool().send(command: "EVAL", with: [
            RESPValue(from: Self.acquireLeaseScript), RESPValue(from: "3"),
            RESPValue(from: leaseOwnerKey(sessionID)), RESPValue(from: epochKey(sessionID)),
            RESPValue(from: activeLeaseEpochKey(sessionID)), RESPValue(from: ownerID.uuidString.lowercased()),
            RESPValue(from: String(durationMilliseconds))
        ]).get()
        if response.int == -1 { throw RedisGameStateRecoveryError.leaseHeld }
        guard let epoch = response.int, epoch > 0 else { throw RedisGameStateRecoveryError.invalidResponse }
        return GameStateSessionLease(sessionID: sessionID, ownerID: ownerID, epoch: UInt64(epoch), durationMilliseconds: durationMilliseconds)
    }

    /// Renews only the currently active owner/epoch. A stale process cannot extend
    /// another process's lease after fencing has advanced.
    @discardableResult
    public func renewLease(_ lease: GameStateSessionLease, durationMilliseconds: Int64? = nil) async throws -> Bool {
        let duration = durationMilliseconds ?? lease.durationMilliseconds
        guard (1_000...300_000).contains(duration) else { throw RedisGameStateRecoveryError.invalidConfiguration }
        let response = try await activePool().send(command: "EVAL", with: [
            RESPValue(from: Self.renewLeaseScript), RESPValue(from: "2"),
            RESPValue(from: leaseOwnerKey(lease.sessionID)), RESPValue(from: activeLeaseEpochKey(lease.sessionID)),
            RESPValue(from: lease.ownerID.uuidString.lowercased()), RESPValue(from: String(lease.epoch)), RESPValue(from: String(duration))
        ]).get()
        return response.int == 1
    }

    /// Releases only the lease represented by this token. Epoch history is retained.
    @discardableResult
    public func releaseLease(_ lease: GameStateSessionLease) async throws -> Bool {
        let response = try await activePool().send(command: "EVAL", with: [
            RESPValue(from: Self.releaseLeaseScript), RESPValue(from: "2"),
            RESPValue(from: leaseOwnerKey(lease.sessionID)), RESPValue(from: activeLeaseEpochKey(lease.sessionID)),
            RESPValue(from: lease.ownerID.uuidString.lowercased()), RESPValue(from: String(lease.epoch))
        ]).get()
        return response.int == 1
    }

    private func finishStart() {
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    public func append(sessionID: UUID, epoch: UInt64, event: GameStateEvent) async throws {
        let encoded = try encode(event)
        let response = try await activePool().send(command: "EVAL", with: [
            RESPValue(from: Self.appendScript), RESPValue(from: "8"), RESPValue(from: streamKey(sessionID)),
            RESPValue(from: epochKey(sessionID)), RESPValue(from: sequenceKey(sessionID)), RESPValue(from: lastEventKey(sessionID)),
            RESPValue(from: lastEventStreamIDKey(sessionID)), RESPValue(from: checkpointRevisionKey(sessionID)),
            RESPValue(from: leaseOwnerKey(sessionID)), RESPValue(from: activeLeaseEpochKey(sessionID)),
            RESPValue(from: String(epoch)), RESPValue(from: String(configuration.maximumEventsPerSession)),
            RESPValue(from: encoded), RESPValue(from: String(event.sequence))
        ]).get()
        if response.int == -1 { throw RedisGameStateRecoveryError.staleEpoch }
        if response.int == -2 { throw RedisGameStateRecoveryError.sequenceConflict }
        if response.int == -3 { throw RedisGameStateRecoveryError.journalCapacityReached }
        if response.int == -4 { throw RedisGameStateRecoveryError.leaseExpired }
        guard response.int == 1 else { throw RedisGameStateRecoveryError.invalidResponse }
    }

    public func save(sessionID: UUID, epoch: UInt64, checkpoint: GameStateCheckpoint) async throws {
        let data = try encoder.encode(checkpoint)
        guard data.count <= configuration.maximumRecordBytes else {
            throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: configuration.maximumRecordBytes)
        }
        let encoded: String
        let chunks: [String]
        if data.count > RedisGameSnapshotManifest.chunkByteLimit {
            let chunked = RedisGameSnapshotManifest.make(for: data)
            guard chunked.manifest.chunkCount <= RedisGameSnapshotManifest.maximumChunkCount else {
                throw RedisGameStateRecoveryError.recoveryLimitExceeded
            }
            encoded = chunked.manifest.encodedValue
            chunks = chunked.chunks
        } else {
            encoded = data.base64EncodedString()
            chunks = []
        }
        let sessionSnapshotKey = snapshotKey(sessionID)
        var chunkKeys: [String] = []
        if !chunks.isEmpty {
            chunkKeys = chunks.indices.map { snapshotChunkKey(sessionID, generation: String(encoded.split(separator: ":")[1]), index: $0 + 1) }
            let pool = try activePool()
            for (key, chunk) in zip(chunkKeys, chunks) {
                let response = try await pool.send(command: "SET", with: [
                    RESPValue(from: key), RESPValue(from: chunk), RESPValue(from: "PX"), RESPValue(from: "3600000")
                ]).get()
                guard response.string == "OK" else { throw RedisGameStateRecoveryError.invalidResponse }
            }
        }
        let chunkByteCount = chunks.reduce(0) { $0 + $1.utf8.count }
        var command: [RESPValue] = [
            RESPValue(from: Self.saveScript), RESPValue(from: String(8 + chunkKeys.count)),
            RESPValue(from: sessionSnapshotKey), RESPValue(from: epochKey(sessionID)),
            RESPValue(from: sequenceKey(sessionID)), RESPValue(from: lastEventStreamIDKey(sessionID)),
            RESPValue(from: streamKey(sessionID)), RESPValue(from: checkpointRevisionKey(sessionID)),
            RESPValue(from: leaseOwnerKey(sessionID)), RESPValue(from: activeLeaseEpochKey(sessionID))
        ]
        command.append(contentsOf: chunkKeys.map { RESPValue(from: $0) })
        command.append(contentsOf: [
            RESPValue(from: String(epoch)), RESPValue(from: String(checkpoint.revision)),
            RESPValue(from: encoded), RESPValue(from: String(chunks.count)), RESPValue(from: String(chunkByteCount))
        ])
        let response = try await activePool().send(command: "EVAL", with: command).get()
        if response.int == -1 { throw RedisGameStateRecoveryError.staleEpoch }
        if response.int == -2 { throw RedisGameStateRecoveryError.sequenceConflict }
        if response.int == -3 { throw RedisGameStateRecoveryError.staleCheckpoint }
        if response.int == -4 { throw RedisGameStateRecoveryError.leaseExpired }
        if response.int == -5 { throw RedisGameStateRecoveryError.invalidResponse }
        guard response.int == 1 else { throw RedisGameStateRecoveryError.invalidResponse }
    }

    public func load(sessionID: UUID) async throws -> (epoch: UInt64, checkpoint: GameStateCheckpoint, events: [GameStateEvent], latestSequence: UInt64)? {
        let pool = try activePool()
        var snapshotJSON = try await pool.get(RedisKey(snapshotKey(sessionID)), as: String.self).get()
        let epochText = try await pool.get(RedisKey(epochKey(sessionID)), as: String.self).get()
        let latestText = try await pool.get(RedisKey(sequenceKey(sessionID)), as: String.self).get()
        if let value = snapshotJSON,
           let manifest = try RedisGameSnapshotManifest.parse(
               value, maximumRecordBytes: configuration.maximumRecordBytes,
               maximumRecoveryBytes: configuration.maximumRecoveryBytes
           ) {
            guard let epochText, UInt64(epochText) != nil, let latestText, UInt64(latestText) != nil else {
                throw RedisGameStateRecoveryError.invalidResponse
            }
            let keys = (1...manifest.chunkCount).map {
                RESPValue(from: snapshotChunkKey(sessionID, generation: manifest.generation, index: $0))
            }
            let response = try await pool.send(command: "MGET", with: keys).get()
            guard let values = response.array,
                  values.count == manifest.chunkCount,
                  values.allSatisfy({ $0.string != nil }) else {
                throw RedisGameStateRecoveryError.invalidResponse
            }
            let chunks = values.compactMap(\.string)
            let data = try manifest.decode(
                chunks: chunks,
                maximumRecordBytes: configuration.maximumRecordBytes,
                maximumRecoveryBytes: configuration.maximumRecoveryBytes
            )
            snapshotJSON = data.base64EncodedString()
        }
        var streamLength = 0
        if snapshotJSON == nil {
            let response = try await pool.send(command: "XLEN", with: [RESPValue(from: streamKey(sessionID))]).get()
            guard let length = response.int, let boundedLength = Int(exactly: length), boundedLength >= 0 else {
                throw RedisGameStateRecoveryError.invalidResponse
            }
            streamLength = boundedLength
        }
        guard let metadata = try decodeRedisGameRecoveryMetadata(
            snapshotJSON: snapshotJSON,
            epochText: epochText,
            sequenceText: latestText,
            streamLength: streamLength,
            maximumRecordBytes: configuration.maximumRecordBytes,
            maximumRecoveryBytes: configuration.maximumRecoveryBytes
        ) else { return nil }
        let epoch = metadata.epoch
        let latestSequence = metadata.latestSequence
        let checkpoint = try decoder.decode(GameStateCheckpoint.self, from: metadata.snapshotData)
        var recovered: [GameStateEvent] = []
        var cursor = "-"
        var count = 0
        var recoveryBytes = metadata.snapshotData.count
        // Fetch several records per round trip when configured record limits make
        // that safe. The response is capped by both a fixed item ceiling and an
        // estimated byte budget; one maximum-sized record remains the hard floor.
        let pageByteBudget = min(configuration.maximumRecoveryBytes, 8_388_608)
        let estimatedBytesPerRecord = max(1, configuration.maximumRecordBytes * 2)
        let pageSize = max(1, min(128, pageByteBudget / estimatedBytesPerRecord))
        while count < configuration.maximumEventsPerSession {
            let response = try await pool.send(command: "XRANGE", with: [
                RESPValue(from: streamKey(sessionID)), RESPValue(from: cursor), RESPValue(from: "+"),
                RESPValue(from: "COUNT"), RESPValue(from: String(pageSize))
            ]).get()
            guard let rows = response.array else { throw RedisGameStateRecoveryError.invalidResponse }
            if rows.isEmpty { break }
            for row in rows {
                guard let fields = row.array, fields.count == 2, let entryID = fields[0].string,
                      let values = fields[1].array, values.count == 2, values[0].string == "entry",
                      let json = values[1].string else { throw RedisGameStateRecoveryError.invalidResponse }
                guard json.utf8.count <= configuration.maximumRecoveryBytes - recoveryBytes else { throw RedisGameStateRecoveryError.recoveryLimitExceeded }
                recoveryBytes += json.utf8.count; count += 1; cursor = "(\(entryID)"
                guard json.utf8.count <= configuration.maximumRecordBytes * 2 else {
                    throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: configuration.maximumRecordBytes)
                }
                guard let data = Data(base64Encoded: json) else { throw RedisGameStateRecoveryError.invalidResponse }
                guard data.count <= configuration.maximumRecordBytes else {
                    throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: configuration.maximumRecordBytes)
                }
                let event = try decoder.decode(GameStateEvent.self, from: data)
                if event.sequence > checkpoint.revision { recovered.append(event) }
            }
            if rows.count < pageSize { break }
        }
        if count == configuration.maximumEventsPerSession {
            let overflow = try await pool.send(command: "XRANGE", with: [
                RESPValue(from: streamKey(sessionID)), RESPValue(from: cursor), RESPValue(from: "+"),
                RESPValue(from: "COUNT"), RESPValue(from: "1")
            ]).get()
            if overflow.array?.isEmpty == false { throw RedisGameStateRecoveryError.recoveryLimitExceeded }
        }
        return (epoch, checkpoint, recovered.sorted { $0.sequence < $1.sequence }, latestSequence)
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard data.count <= configuration.maximumRecordBytes else { throw RedisGameStateRecoveryError.recordTooLarge(maximumBytes: configuration.maximumRecordBytes) }
        return data.base64EncodedString()
    }
    private func activePool() throws -> RedisConnectionPool { guard let pool else { throw RedisGameStateRecoveryError.notStarted }; return pool }
    private func streamKey(_ id: UUID) -> String { "\(configuration.keyPrefix):session:\(id.uuidString.lowercased()):events" }
    private func snapshotKey(_ id: UUID) -> String { "\(configuration.keyPrefix):session:\(id.uuidString.lowercased()):snapshot" }
    private func snapshotChunkKey(_ id: UUID, generation: String, index: Int) -> String {
        "\(snapshotKey(id)):chunk:\(generation):\(index)"
    }
    private func epochKey(_ id: UUID) -> String { "\(configuration.keyPrefix):session:\(id.uuidString.lowercased()):epoch" }
    private func sequenceKey(_ id: UUID) -> String { "\(configuration.keyPrefix):session:\(id.uuidString.lowercased()):sequence" }
    private func lastEventKey(_ id: UUID) -> String { "\(configuration.keyPrefix):session:\(id.uuidString.lowercased()):last-event" }
    private func lastEventStreamIDKey(_ id: UUID) -> String { "\(configuration.keyPrefix):session:\(id.uuidString.lowercased()):last-event-id" }
    private func checkpointRevisionKey(_ id: UUID) -> String { "\(configuration.keyPrefix):session:\(id.uuidString.lowercased()):checkpoint-revision" }
    private func leaseOwnerKey(_ id: UUID) -> String { "\(configuration.keyPrefix):session:\(id.uuidString.lowercased()):lease-owner" }
    private func activeLeaseEpochKey(_ id: UUID) -> String { "\(configuration.keyPrefix):session:\(id.uuidString.lowercased()):lease-epoch" }
    private static func tlsClient(group: EventLoopGroup, serverName: String) -> ClientBootstrap {
        ClientBootstrap(group: group).channelInitializer { channel in
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.certificateVerification = .fullVerification
            do {
                let context = try NIOSSLContext(configuration: tls)
                try channel.pipeline.syncOperations.addHandler(
                    NIOSSLClientHandler(context: context, serverHostname: serverName)
                )
                return channel.eventLoop.makeSucceededFuture(())
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }
    }
    private static func close(_ pool: RedisConnectionPool) async throws {
        let promise = pool.eventLoop.makePromise(of: Void.self)
        pool.close(promise: promise)
        try await promise.futureResult.get()
    }
}

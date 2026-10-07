import Foundation

public enum GameServerMode: String, Codable, CaseIterable, Sendable {
    case light
    case medium
    case high
}

public struct GameServerResourceLimits: Codable, Equatable, Sendable {
    public let maximumSessions: Int
    public let maximumQueuedBytes: Int
    public let maximumMessageBytes: Int
    public let maximumMessagesPerSecondPerPlayer: Int

    public init(
        maximumSessions: Int,
        maximumQueuedBytes: Int,
        maximumMessageBytes: Int,
        maximumMessagesPerSecondPerPlayer: Int
    ) {
        self.maximumSessions = maximumSessions
        self.maximumQueuedBytes = maximumQueuedBytes
        self.maximumMessageBytes = maximumMessageBytes
        self.maximumMessagesPerSecondPerPlayer = maximumMessagesPerSecondPerPlayer
    }
}

/// Starter bounds for the authoritative realtime input loop. These are admission
/// limits, not measured performance or player-capacity guarantees.
public struct GameServerFixedStepLimits: Codable, Equatable, Sendable {
    public let tickRateHz: Int
    public let maximumQueuedInputs: Int
    public let maximumInputsPerTick: Int
    public let maximumQueuedInputsPerPlayer: Int
    public let maximumQueuedBytesPerPlayer: Int
    public let maximumConsecutiveOverruns: Int
}

/// Starter configuration only. Limits are conservative examples, not capacity guarantees.
public struct GameServerModeProfile: Codable, Equatable, Sendable {
    public let mode: GameServerMode
    public let controlTransport: String
    public let realtimeTransport: String
    public let wireFormat: String
    public let memoryManagement: String
    public let udpEnabled: Bool
    public let udpRequiresSecureDatagramAdapter: Bool
    public let resourceLimits: GameServerResourceLimits
    public let fixedStep: GameServerFixedStepLimits?
    public let notes: [String]

    /// Builds the bounded input queue directly from this template's session and
    /// byte limits. Older templates without `fixedStep` must be updated first.
    public func makeRealtimeSimulation(initialTick: UInt64 = 0) throws -> GameRealtimeSimulation {
        guard let fixedStep else { throw GameServerError.invalidConfiguration }
        return try GameRealtimeSimulation(
            maximumQueuedInputs: fixedStep.maximumQueuedInputs,
            maximumInputBytes: resourceLimits.maximumMessageBytes,
            maximumPlayers: resourceLimits.maximumSessions,
            maximumQueuedBytes: resourceLimits.maximumQueuedBytes,
            maximumQueuedInputsPerPlayer: fixedStep.maximumQueuedInputsPerPlayer,
            maximumQueuedBytesPerPlayer: fixedStep.maximumQueuedBytesPerPlayer,
            initialTick: initialTick
        )
    }

    /// Creates the monotonic tick driver using the cadence and per-tick work cap
    /// from this template. The handler runs synchronously and must not do I/O.
    public func makeRealtimeFixedStepDriver(
        simulation: GameRealtimeSimulation,
        handler: @escaping GameRealtimeFixedStepDriver.TickHandler
    ) throws -> GameRealtimeFixedStepDriver {
        guard let fixedStep else { throw GameServerError.invalidConfiguration }
        let configuration = try GameRealtimeFixedStepConfiguration(
            tickRateHz: fixedStep.tickRateHz,
            maximumInputsPerTick: fixedStep.maximumInputsPerTick,
            maximumConsecutiveOverruns: fixedStep.maximumConsecutiveOverruns
        )
        return GameRealtimeFixedStepDriver(
            simulation: simulation,
            configuration: configuration,
            handler: handler
        )
    }

    public static func preset(_ mode: GameServerMode) -> Self {
        switch mode {
        case .light:
            return Self(
                mode: mode,
                controlTransport: "grpc-over-tls",
                realtimeTransport: "websocket-over-tls",
                wireFormat: "json",
                memoryManagement: "swift-arc-default",
                udpEnabled: false,
                udpRequiresSecureDatagramAdapter: false,
                resourceLimits: .init(maximumSessions: 32, maximumQueuedBytes: 2_097_152, maximumMessageBytes: 65_536, maximumMessagesPerSecondPerPlayer: 60),
                fixedStep: .init(tickRateHz: 20, maximumQueuedInputs: 2_048, maximumInputsPerTick: 128, maximumQueuedInputsPerPlayer: 64, maximumQueuedBytesPerPlayer: 65_536, maximumConsecutiveOverruns: 3),
                notes: ["Swift uses ARC; there is no runtime garbage-collection switch.", "Starter limits must be tuned with measurements for the deployment host."]
            )
        case .medium:
            return Self(
                mode: mode,
                controlTransport: "grpc-over-tls",
                realtimeTransport: "websocket-over-tls",
                wireFormat: "json",
                memoryManagement: "ownership-oriented-buffer-and-value-design-with-arc",
                udpEnabled: false,
                udpRequiresSecureDatagramAdapter: false,
                resourceLimits: .init(maximumSessions: 256, maximumQueuedBytes: 16_777_216, maximumMessageBytes: 65_536, maximumMessagesPerSecondPerPlayer: 120),
                fixedStep: .init(tickRateHz: 30, maximumQueuedInputs: 16_384, maximumInputsPerTick: 1_024, maximumQueuedInputsPerPlayer: 128, maximumQueuedBytesPerPlayer: 131_072, maximumConsecutiveOverruns: 3),
                notes: ["Ownership and borrowing can reduce copies and retain/release traffic; ARC remains active.", "Starter limits must be tuned with measurements for the deployment host."]
            )
        case .high:
            return Self(
                mode: mode,
                controlTransport: "grpc-over-tls",
                realtimeTransport: "udp-datagram",
                wireFormat: "binary",
                memoryManagement: "ownership-oriented-buffer-and-value-design-with-arc",
                udpEnabled: false,
                udpRequiresSecureDatagramAdapter: true,
                resourceLimits: .init(maximumSessions: 2_048, maximumQueuedBytes: 67_108_864, maximumMessageBytes: 1_200, maximumMessagesPerSecondPerPlayer: 240),
                fixedStep: .init(tickRateHz: 60, maximumQueuedInputs: 65_536, maximumInputsPerTick: 8_192, maximumQueuedInputsPerPlayer: 256, maximumQueuedBytesPerPlayer: 262_144, maximumConsecutiveOverruns: 3),
                notes: ["Secure client/server UDP codecs now share a fixed interoperability vector; UDP stays disabled until the app provisions session keys and validates socket/abuse behavior.", "Swift uses ARC; there is no runtime garbage-collection switch.", "Starter limits are not benchmarked capacity guarantees."]
            )
        }
    }
}

/// Secret-free starter configuration for the optional Redis recovery adapter.
/// Durability values are deployment guidance; they do not claim a guaranteed RPO.
public struct GameServerRecoveryProfile: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let store: String
    public let connection: Connection
    public let limits: Limits
    public let tickWriter: TickWriter
    public let lease: Lease
    public let persistence: Persistence

    public struct Connection: Codable, Equatable, Sendable {
        public let defaultHost: String
        public let defaultPort: Int
        public let database: Int
        public let hostEnvironmentVariable: String
        public let portEnvironmentVariable: String
        public let usernameEnvironmentVariable: String
        public let passwordEnvironmentVariable: String
        public let tlsRequiredForRemoteHosts: Bool
        public let keyPrefix: String
        public let maximumConnections: Int
    }

    public struct Limits: Codable, Equatable, Sendable {
        public let maximumPendingStateBytesPerQueue: Int
        public let maximumRetainedStateBytes: Int
        public let maximumEventsPerSession: Int
        public let maximumRecordBytes: Int
        public let maximumRecoveryBytes: Int
        public let maximumRetainedStates: Int
        public let maximumSnapshotBytes: Int
        public let checkpointEveryEvents: Int
        public let checkpointIntervalMilliseconds: Int?
    }

    public struct Lease: Codable, Equatable, Sendable {
        public let durationMilliseconds: Int
        public let renewBeforeMilliseconds: Int
        public let newOwnerUUIDPerProcess: Bool
    }

    public struct Persistence: Codable, Equatable, Sendable {
        public let delivery: String
        public let durableCommandCommit: String
        public let durableTickBatchCommit: String
        public let commandAppendFailure: String
        public let recommendedRedisSettings: [String]
        public let guaranteedRecoveryPointObjective: String
        public let onLeaseLoss: String
    }

    public struct TickWriter: Codable, Equatable, Sendable {
        public let maximumStateBytes: Int
        public let maximumTransitionBytes: Int
        public let maximumTransitionsPerTick: Int
        public let maximumRandomDrawsPerTick: Int
        public let maximumTicksPerBatch: Int
        public let maximumTransitionsPerBatch: Int
        public let maximumRandomDrawsPerBatch: Int
        public let maximumBatchBytes: Int
        public let maximumProcessedBatches: Int
        public let maximumReplayBatches: Int
        public let maximumCheckpointBytes: Int
        public let maximumPendingBatches: Int
        public let maximumPendingBytes: Int
    }

    public static let redis = Self(
        schemaVersion: 3,
        store: "redis-streams-and-checkpoints",
        connection: Connection(
            defaultHost: "127.0.0.1",
            defaultPort: 6379,
            database: 0,
            hostEnvironmentVariable: "PEARFY_GAME_REDIS_HOST",
            portEnvironmentVariable: "PEARFY_GAME_REDIS_PORT",
            usernameEnvironmentVariable: "PEARFY_GAME_REDIS_USERNAME",
            passwordEnvironmentVariable: "PEARFY_GAME_REDIS_PASSWORD",
            tlsRequiredForRemoteHosts: true,
            keyPrefix: "pearfy:game-recovery",
            maximumConnections: 4
        ),
        limits: Limits(
            maximumPendingStateBytesPerQueue: 1_048_576,
            maximumRetainedStateBytes: 67_108_864,
            maximumEventsPerSession: 100_000,
            maximumRecordBytes: 2_097_152,
            maximumRecoveryBytes: 67_108_864,
            maximumRetainedStates: 10_000,
            maximumSnapshotBytes: 16_777_216,
            checkpointEveryEvents: 100,
            checkpointIntervalMilliseconds: 30_000
        ),
        tickWriter: TickWriter(
            maximumStateBytes: 4_194_304,
            maximumTransitionBytes: 65_536,
            maximumTransitionsPerTick: 1_024,
            maximumRandomDrawsPerTick: 4_096,
            maximumTicksPerBatch: 120,
            maximumTransitionsPerBatch: 8_192,
            maximumRandomDrawsPerBatch: 8_192,
            maximumBatchBytes: 1_048_576,
            maximumProcessedBatches: 10_000,
            maximumReplayBatches: 100_000,
            maximumCheckpointBytes: 16_777_216,
            maximumPendingBatches: 32,
            maximumPendingBytes: 16_777_216
        ),
        lease: Lease(
            durationMilliseconds: 15_000,
            renewBeforeMilliseconds: 5_000,
            newOwnerUUIDPerProcess: true
        ),
        persistence: Persistence(
            delivery: "best-effort-async; queue overflow can replace older state updates",
            durableCommandCommit: "RedisDurableGameCommandSession appends the validated command and resulting-state digest before changing committed in-memory state; openAsync supports actor-backed reducers and RedisDurableGameCoopSession covers bounded co-op lifecycle/objective transitions",
            durableTickBatchCommit: "RedisDurableGameTickBatchQueue stages bounded contiguous server-authored ticks; a separate async writer must commit them before publication or acknowledgement",
            commandAppendFailure: "keep the last committed state; retry the same command ID or stop admission and apply backpressure",
            recommendedRedisSettings: ["appendonly yes", "appendfsync everysec"],
            guaranteedRecoveryPointObjective: "none; depends on queue delivery, Redis persistence, replication and failover",
            onLeaseLoss: "stop authoritative mutations and recover under a newly acquired fencing epoch"
        )
    )
}

public enum GameServerRecipe: String, Codable, CaseIterable, Sendable {
    case turnBased = "turn-based"
    case fps
    case friendslop
    case mmo
    case rooms
    case dedicated
}

/// A composition guide, not a claim that Pearfy implements the game simulation.
public struct GameServerRecipeProfile: Codable, Equatable, Sendable {
    public let recipe: GameServerRecipe
    public let mode: GameServerMode
    public let requiredModules: [String]
    public let optionalModules: [String]
    public let capabilities: [String]
    public let applicationResponsibilities: [String]
    public let productionGates: [String]

    public static func preset(_ recipe: GameServerRecipe) -> Self {
        let commonGates = [
            "Starter limits are not benchmarked capacity guarantees.",
            "The application owns authentication, game rules, payload schemas and authoritative simulation."
        ]
        switch recipe {
        case .turnBased:
            return Self(
                recipe: recipe, mode: .light,
                requiredModules: ["gameserver", "gameserver-turn-based", "gameserver-grpc", "gameserver-transport"],
                optionalModules: ["gameserver-turn-based-postgres", "gameserver-turn-based-redis", "gameserver-redis-recovery", "gameserver-postgres", "gameserver-devkit"],
                capabilities: ["Async turn-based reducer with bounded event history and deterministic checkpoint replay", "Atomic compare-and-append store boundary with append-before-publish", "Optional Redis write-ahead commit for discrete commands", "WSS gameplay transport"],
                applicationResponsibilities: ["Implement a transactional GameTurnBasedCommandStore or use the in-memory GameCommandProcessor for volatile sessions", "Define deterministic authorization, turn validation, reducer and command schema", "When Redis recovery is enabled, use RedisDurableGameCommandSession and return success only after append; call it outside the simulation tick"],
                productionGates: commonGates + ["Validate the selected transactional store under process crash/restart and its configured recovery policy; verify deployment RPO, database permissions and retention limits."]
            )
        case .fps:
            return Self(
                recipe: recipe, mode: .high,
                requiredModules: ["gameserver", "gameserver-grpc", "gameserver-transport", "gameserver-realtime"],
                optionalModules: ["gameserver-redis-recovery", "gameserver-devkit", "gameserver-agones"],
                capabilities: ["60Hz monotonic fixed-step driver with at most 8,192 inputs per tick and no catch-up bursts", "Bounded realtime input queue and spatial interest snapshots", "Binary secure UDP codec and listener"],
                applicationResponsibilities: ["Implement authoritative physics, hit validation, lag compensation and snapshot/delta protocol", "Provision a fresh session secret through authenticated confidential control-plane delivery"],
                productionGates: commonGates + ["UDP remains disabled until full client/server socket, key rotation, abuse and overload validation passes.", "Measure tick cost, allocations, memory, latency and overload behavior on the target host."]
            )
        case .friendslop:
            return Self(
                recipe: recipe, mode: .medium,
                requiredModules: ["gameserver", "gameserver-grpc", "gameserver-transport", "gameserver-realtime"],
                optionalModules: ["gameserver-matchmaking-postgres", "gameserver-redis-recovery", "gameserver-devkit", "gameserver-agones", "gameserver-threat-director", "gameserver-npc-learn"],
                capabilities: ["Private bounded rooms with invitations and reconnect grace", "Co-op objective state primitives", "Optional bounded deterministic threat director and typed Jev NPC decisions", "Optional Redis write-ahead commit for discrete mission and RNG decisions", "Bounded realtime input and local AOI snapshots"],
                applicationResponsibilities: ["Implement mission lifecycle and outcomes; validate threat-director and Jev recommendations against the live world before scheduling authoritative NPC actions", "Filter private evidence and player-role state before each recipient's snapshot; do not journal every movement tick"],
                productionGates: commonGates + ["Test deterministic session seeds, reconnect, player absence, victory, defeat, append failure/retry and process restart."]
            )
        case .mmo:
            return Self(
                recipe: recipe, mode: .high,
                requiredModules: ["gameserver", "gameserver-grpc", "gameserver-transport", "gameserver-realtime", "gameserver-world-postgres"],
                optionalModules: ["gameserver-redis-recovery", "gameserver-postgres", "gameserver-matchmaking-postgres", "gameserver-agones", "gameserver-devkit"],
                capabilities: ["Fenced PostgreSQL zone leases and bounded entity handoff", "60Hz monotonic fixed-step target with bounded per-tick input work", "Bounded local AOI snapshots", "Secure binary UDP transport primitives"],
                applicationResponsibilities: ["Implement zone simulation, entity snapshot/delta replication, visibility policy and client handoff", "Stop writes when zone lease renewal fails and reconcile assignments after ambiguous failures"],
                productionGates: commonGates + ["Exercise process crash, lease takeover, entity migration and recovery across replicas.", "Benchmark per-zone tick, memory, serialization and fanout; enforce explicit admission/backpressure limits.", "UDP remains disabled until full client/server socket and abuse validation passes."]
            )
        case .rooms:
            return Self(
                recipe: recipe, mode: .light,
                requiredModules: ["gameserver", "gameserver-grpc", "gameserver-transport"],
                optionalModules: ["gameserver-matchmaking-postgres", "gameserver-devkit", "gameserver-redis-recovery", "gameserver-agones"],
                capabilities: ["Bounded in-process rooms, private invitations and reconnect grace", "WSS gameplay and unary gRPC control transports"],
                applicationResponsibilities: ["Authenticate room actions and define presence/host-transfer policy", "Use PostgreSQL matchmaking only when cross-replica queue claims are needed"],
                productionGates: commonGates + ["Room ownership and ticket revocation are process-local unless the application adds a shared authority."]
            )
        case .dedicated:
            return Self(
                recipe: recipe, mode: .medium,
                requiredModules: ["gameserver", "gameserver-grpc", "gameserver-transport", "gameserver-agones"],
                optionalModules: ["gameserver-redis-recovery", "gameserver-postgres", "gameserver-devkit"],
                capabilities: ["WSS gameplay listener", "Agones SDK lifecycle and mTLS allocator client"],
                applicationResponsibilities: ["Deploy/configure Fleet and define region/label selection", "Mark the process ready only after authoritative state and gameplay transport are initialized"],
                productionGates: commonGates + ["Validate allocation and shutdown behavior against a real Agones test cluster."]
            )
        }
    }
}

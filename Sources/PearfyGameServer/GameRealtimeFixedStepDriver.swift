import Foundation

public struct GameRealtimeFixedStepConfiguration: Sendable, Equatable {
    public let tickRateHz: Int
    public let maximumInputsPerTick: Int
    public let sleepToleranceNanoseconds: Int
    public let maximumConsecutiveOverruns: Int

    public static let standard = GameRealtimeFixedStepConfiguration(
        tickRateHz: 60,
        maximumInputsPerTick: 512,
        sleepToleranceNanoseconds: 0,
        maximumConsecutiveOverruns: 3,
        validated: ()
    )

    public init(
        tickRateHz: Int = 60,
        maximumInputsPerTick: Int = 512,
        sleepToleranceNanoseconds: Int = 0,
        maximumConsecutiveOverruns: Int = 3
    ) throws {
        guard (1...240).contains(tickRateHz),
              (1...100_000).contains(maximumInputsPerTick),
              (0...10_000_000).contains(sleepToleranceNanoseconds),
              (1...1_000).contains(maximumConsecutiveOverruns) else {
            throw GameServerError.invalidConfiguration
        }
        self.tickRateHz = tickRateHz
        self.maximumInputsPerTick = maximumInputsPerTick
        self.sleepToleranceNanoseconds = sleepToleranceNanoseconds
        self.maximumConsecutiveOverruns = maximumConsecutiveOverruns
    }

    private init(tickRateHz: Int, maximumInputsPerTick: Int, sleepToleranceNanoseconds: Int, maximumConsecutiveOverruns: Int, validated: Void) {
        self.tickRateHz = tickRateHz
        self.maximumInputsPerTick = maximumInputsPerTick
        self.sleepToleranceNanoseconds = sleepToleranceNanoseconds
        self.maximumConsecutiveOverruns = maximumConsecutiveOverruns
    }

    fileprivate var period: Duration {
        .nanoseconds(Int64(1_000_000_000 / tickRateHz))
    }

    fileprivate var sleepTolerance: Duration {
        .nanoseconds(Int64(sleepToleranceNanoseconds))
    }
}

public struct GameRealtimeFixedStepMetrics: Sendable, Equatable {
    public let isRunning: Bool
    public let isFailed: Bool
    public let isOverloaded: Bool
    public let completedTicks: UInt64
    public let overrunCount: UInt64
    public let consecutiveOverrunCount: Int
    public let tickAdvanceFailureCount: UInt64
    public let handlerFailureCount: UInt64
    public let lastTickDurationNanoseconds: UInt64
}

/// Runs one synchronous application reducer at a monotonic fixed-step cadence.
/// A slow reducer is never caught up with a burst of ticks: the next deadline is
/// re-anchored after the overrun. Sustained overruns close input admission and stop
/// the driver. The reducer must not perform network or storage I/O.
public actor GameRealtimeFixedStepDriver {
    public typealias TickHandler = @Sendable (GameRealtimeTick) throws -> Void

    private let simulation: GameRealtimeSimulation
    private let configuration: GameRealtimeFixedStepConfiguration
    private let handler: TickHandler
    private let clock = ContinuousClock()
    private var task: Task<Void, Never>?
    private var running = false
    private var failed = false
    private var overloaded = false
    private var completedTicks: UInt64 = 0
    private var overrunCount: UInt64 = 0
    private var consecutiveOverrunCount = 0
    private var tickAdvanceFailureCount: UInt64 = 0
    private var handlerFailureCount: UInt64 = 0
    private var lastTickDurationNanoseconds: UInt64 = 0

    public init(
        simulation: GameRealtimeSimulation,
        configuration: GameRealtimeFixedStepConfiguration = .standard,
        handler: @escaping TickHandler
    ) {
        self.simulation = simulation
        self.configuration = configuration
        self.handler = handler
    }

    /// Starts the driver once. Returns `false` if it is running, stopping or failed.
    @discardableResult
    public func start() -> Bool {
        guard task == nil, !failed else { return false }
        running = true
        task = Task { await runLoop() }
        return true
    }

    /// Cancels the cadence and waits for the current synchronous handler to return.
    public func stop() async {
        guard let task else { return }
        task.cancel()
        await task.value
    }

    public func metrics() -> GameRealtimeFixedStepMetrics {
        GameRealtimeFixedStepMetrics(
            isRunning: running,
            isFailed: failed,
            isOverloaded: overloaded,
            completedTicks: completedTicks,
            overrunCount: overrunCount,
            consecutiveOverrunCount: consecutiveOverrunCount,
            tickAdvanceFailureCount: tickAdvanceFailureCount,
            handlerFailureCount: handlerFailureCount,
            lastTickDurationNanoseconds: lastTickDurationNanoseconds
        )
    }

    private func runLoop() async {
        defer {
            running = false
            task = nil
        }

        var deadline = clock.now
        while !Task.isCancelled {
            deadline = deadline.advanced(by: configuration.period)
            do {
                try await clock.sleep(until: deadline, tolerance: configuration.sleepTolerance)
            } catch {
                if Task.isCancelled { break }
                continue
            }
            guard !Task.isCancelled else { break }

            let startedAt = clock.now
            let tick: GameRealtimeTick
            do {
                tick = try await simulation.advanceTick(maximumInputs: configuration.maximumInputsPerTick)
            } catch {
                if tickAdvanceFailureCount < .max { tickAdvanceFailureCount += 1 }
                failed = true
                await simulation.closeInputAdmission()
                break
            }

            do {
                try handler(tick)
            } catch {
                if handlerFailureCount < .max { handlerFailureCount += 1 }
                failed = true
                await simulation.closeInputAdmission()
                break
            }

            let finishedAt = clock.now
            let duration = startedAt.duration(to: finishedAt)
            lastTickDurationNanoseconds = Self.nanoseconds(duration)
            if completedTicks < .max { completedTicks += 1 }

            if finishedAt >= deadline.advanced(by: configuration.period) {
                if overrunCount < .max { overrunCount += 1 }
                consecutiveOverrunCount += 1
                if consecutiveOverrunCount >= configuration.maximumConsecutiveOverruns {
                    overloaded = true
                    failed = true
                    await simulation.closeInputAdmission()
                    break
                }
                // Drop missed schedule slots. The next simulation step waits a full
                // period after this overrun, keeping overload from creating a busy loop.
                deadline = finishedAt
            } else {
                consecutiveOverrunCount = 0
            }
        }
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0 else { return 0 }
        let (wholeSeconds, secondsOverflow) = UInt64(components.seconds)
            .multipliedReportingOverflow(by: 1_000_000_000)
        guard !secondsOverflow else { return .max }
        let fractionalNanoseconds = UInt64(max(0, components.attoseconds) / 1_000_000_000)
        let (total, additionOverflow) = wholeSeconds.addingReportingOverflow(fractionalNanoseconds)
        return additionOverflow ? .max : total
    }
}

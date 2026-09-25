import PearfyJobs
import Testing

@Test func fixedDelaySchedulerExecutesWithoutOverlappingAndStopsCooperatively() async throws {
    let scheduler = JobScheduler()
    let probe = JobProbe()
    try await scheduler.schedule("refresh", every: .milliseconds(5)) {
        await probe.begin()
        do {
            try await Task.sleep(for: .milliseconds(12))
        } catch {
            await probe.end()
            throw error
        }
        await probe.end()
    }
    try await scheduler.start()
    try await Task.sleep(for: .milliseconds(55))
    try await scheduler.stop()

    let snapshot = await scheduler.snapshot()
    let probeState = await probe.state
    #expect(snapshot.first?.executions ?? 0 >= 2)
    #expect(snapshot.first?.failures == 0)
    #expect(probeState.maximumInFlight == 1)
    #expect(probeState.inFlight == 0)
}

@Test func schedulerRejectsDuplicateNamesAndInvalidIntervals() async throws {
    let scheduler = JobScheduler()
    try await scheduler.schedule("unique", every: .seconds(1)) {}
    var duplicateRejected = false
    do {
        try await scheduler.schedule("unique", every: .seconds(1)) {}
    } catch JobSchedulerError.duplicateJob {
        duplicateRejected = true
    }
    var intervalRejected = false
    do {
        try await scheduler.schedule("zero", every: .zero) {}
    } catch JobSchedulerError.invalidInterval {
        intervalRejected = true
    }
    #expect(duplicateRejected)
    #expect(intervalRejected)
}

@Test func schedulerBoundsRegisteredJobs() async throws {
    let scheduler = JobScheduler(maximumJobs: 1)
    try await scheduler.schedule("first", every: .seconds(1)) {}

    var rejected = false
    do {
        try await scheduler.schedule("second", every: .seconds(1)) {}
    } catch JobSchedulerError.maximumJobs(1) {
        rejected = true
    }
    #expect(rejected)
}

private actor JobProbe {
    struct State: Sendable {
        let inFlight: Int
        let maximumInFlight: Int
    }

    private var inFlight = 0
    private var maximumInFlight = 0

    var state: State { State(inFlight: inFlight, maximumInFlight: maximumInFlight) }

    func begin() {
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
    }

    func end() { inFlight -= 1 }
}

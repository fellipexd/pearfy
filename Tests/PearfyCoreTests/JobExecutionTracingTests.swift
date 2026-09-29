import Foundation
import PearfyJobs
import Testing

@Test func schedulerReportsCompletedExecutionTimingAndOutcome() async throws {
    let executions = JobExecutionProbe()
    let scheduler = JobScheduler(onExecution: { execution in
        await executions.append(execution)
    })
    try await scheduler.schedule("refresh", every: .milliseconds(5)) {
        throw JobExecutionTestFailure()
    }
    try await scheduler.start()

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while await executions.values.isEmpty, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try await scheduler.stop()

    let execution = try #require(await executions.values.first)
    #expect(execution.name == "refresh")
    #expect(execution.startedAt.timeIntervalSince1970 > 0)
    #expect(execution.durationMilliseconds.isFinite && execution.durationMilliseconds >= 0)
    #expect(execution.status == .failed)
}

@Test func schedulerCanRunAWorkImmediatelyBeforeItsFirstDelay() async throws {
    let executions = JobExecutionProbe()
    let scheduler = JobScheduler(onExecution: { execution in
        await executions.append(execution)
    })
    try await scheduler.schedule("startup-sync", every: .seconds(30), runImmediately: true) {}
    try await scheduler.start()

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while await executions.values.isEmpty, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try await scheduler.stop()

    let execution = try #require(await executions.values.first)
    #expect(execution.name == "startup-sync")
    #expect(execution.status == .succeeded)
}

private actor JobExecutionProbe {
    private(set) var values: [JobExecution] = []

    func append(_ execution: JobExecution) {
        values.append(execution)
    }
}

private struct JobExecutionTestFailure: Error {}

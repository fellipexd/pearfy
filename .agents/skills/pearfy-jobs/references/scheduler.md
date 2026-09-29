# Scheduler reference

- Source: `Sources/PearfyJobs/JobScheduler.swift`.
- Scheduling is local to one process. Confirm exact start/stop method names and cancellation behavior in source.
- An optional `onExecution` observer receives completed run names, timestamps, duration and success/failure status; it receives no thrown error or handler payload.
- `runImmediately: true` runs a definition once when the scheduler starts, then waits the configured fixed delay between later executions.
- Do not persist credentials or high-cardinality payloads as job metadata.
- Multi-instance scheduling requires an external durable lease/queue design; it is not supplied by this module.
- Relevant tests cover duplicate names, invalid intervals, fixed delay, non-overlap and cooperative stop.

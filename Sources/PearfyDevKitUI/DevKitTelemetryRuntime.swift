import Foundation
import PearfyObservability
import PearfyWeb

/// Generic in-process instrumentation shared by HTTP, PostgreSQL, and DevKit.
/// Pass `telemetryStore` (and optionally `metricsRegistry`) to Pearfy adapters,
/// then use `install(on:configuration:)` to attach HTTP and process sources.
public struct DevKitTelemetryRuntime: Sendable {
    public let metricsRegistry: MetricsRegistry
    public let telemetryStore: InProcessTelemetryStore
    public let workTraceRecorder: DevKitWorkTraceRecorder

    private let processSampler: DevKitProcessResourceSampler

    public init(
        metricsRegistry: MetricsRegistry = MetricsRegistry(),
        telemetryStore: InProcessTelemetryStore = InProcessTelemetryStore(),
        workTraceRecorder: DevKitWorkTraceRecorder = DevKitWorkTraceRecorder(),
        processSampler: DevKitProcessResourceSampler = DevKitProcessResourceSampler()
    ) {
        self.metricsRegistry = metricsRegistry
        self.telemetryStore = telemetryStore
        self.workTraceRecorder = workTraceRecorder
        self.processSampler = processSampler
    }

    /// Installs HTTP collection and returns a complete generic snapshot source.
    /// The caller remains responsible for installing the bearer-protected UI.
    public func install(
        on router: HTTPRouter,
        configuration: DevKitConfiguration
    ) async throws -> DevKitSnapshotSource {
        guard configuration.enabled else { return .empty() }
        try PearfyDevKitUI.validate(configuration)
        try await router.use(HTTPMetricsMiddleware.make(registry: metricsRegistry, telemetry: telemetryStore))
        await processSampler.start()

        let instanceID = configuration.instanceID ?? "local"
        let metricsSource = DevKitSnapshotSource.httpMetrics(
            metricsRegistry,
            router: router,
            telemetry: telemetryStore,
            instanceID: instanceID
        )
        return DevKitSnapshotSource { query in
            let snapshot = try await metricsSource.snapshot(for: query)
            let matchesInstance = query.instanceID == nil || query.instanceID == instanceID
            let resources = matchesInstance ? await processSampler.latestSample() : nil
            let workTraces = matchesInstance
                ? await workTraceRecorder.snapshot(window: query.window)
                : []
            let overview = DevKitOverview(
                generatedAt: snapshot.overview.generatedAt,
                requestedWindow: snapshot.overview.requestedWindow,
                windowApplied: snapshot.overview.windowApplied,
                scope: snapshot.overview.scope,
                requestCount: snapshot.overview.requestCount,
                errorCount: snapshot.overview.errorCount,
                averageLatencyMilliseconds: snapshot.overview.averageLatencyMilliseconds,
                p50Milliseconds: snapshot.overview.p50Milliseconds,
                p95Milliseconds: snapshot.overview.p95Milliseconds,
                p99Milliseconds: snapshot.overview.p99Milliseconds,
                latencyPercentilesEstimated: snapshot.overview.latencyPercentilesEstimated,
                cpuPercent: resources?.cpuPercent,
                memoryBytes: resources?.residentMemoryBytes,
                storageBytes: snapshot.overview.storageBytes
            )
            let instances = resources.map {
                [DevKitInstance(
                    id: instanceID,
                    serviceName: configuration.serviceName,
                    sampledAt: $0.sampledAt,
                    cpuPercent: $0.cpuPercent,
                    memoryBytes: $0.residentMemoryBytes,
                    status: "local"
                )]
            } ?? []
            return DevKitSnapshot(
                overview: overview,
                routeMetrics: snapshot.routeMetrics,
                traces: snapshot.traces + workTraces,
                logs: snapshot.logs,
                instances: instances,
                queries: snapshot.queries,
                availableSources: snapshot.availableSources + ["process-resources", "work-traces"]
            )
        }
    }
}

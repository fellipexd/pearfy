import Foundation
import PearfyDevKitUI
import PearfyGameServer
import PearfyWeb

/// Joins the optional state manager to the bearer-protected DevKit dashboard.
public enum PearfyGameServerDevKit {
    /// Installs the protected dashboard with the process-wide manager by default.
    /// The app still supplies an explicit bearer token and owns router lifecycle.
    public static func install(
        on router: HTTPRouter,
        configuration: DevKitConfiguration,
        manager: GameServerStateManager = .shared,
        merging base: DevKitSnapshotSource = .empty()
    ) async throws {
        try await PearfyDevKitUI.install(
            on: router,
            configuration: configuration,
            source: source(manager: manager, merging: base)
        )
    }

    public static func source(
        manager: GameServerStateManager = .shared,
        merging base: DevKitSnapshotSource = .empty()
    ) -> DevKitSnapshotSource {
        DevKitSnapshotSource { query in
            let snapshot = try await base.snapshot(for: query)
            let page = await manager.snapshot(offset: query.stateOffset, limit: query.stateLimit)
            let states = page.records.map { record -> DevKitGameState in
                let preview = Data(record.payload.prefix(1_024)).base64EncodedString()
                return DevKitGameState(
                    id: record.id,
                    revision: record.revision,
                    updatedAt: record.updatedAt,
                    payloadBase64Preview: preview,
                    payloadBytes: record.payload.count,
                    truncated: record.payload.count > 1_024
                )
            }
            return DevKitSnapshot(
                overview: snapshot.overview,
                routeMetrics: snapshot.routeMetrics,
                traces: snapshot.traces,
                logs: snapshot.logs,
                instances: snapshot.instances,
                queries: snapshot.queries,
                availableSources: snapshot.availableSources + ["gameserver-state"],
                gameStates: states,
                gameStateCount: page.total
            )
        }
    }
}

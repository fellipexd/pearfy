import PearfyDI

/// Each test context owns its own container and singleton cache. A copied
/// context reuses registration definitions but never production instances.
public actor TestContext {
    public let container: ServiceContainer

    public init() {
        container = ServiceContainer()
    }

    public init(copying container: ServiceContainer) async {
        self.container = await container.isolatedCopy()
    }

    public func override<T: Sendable>(
        _ type: T.Type = T.self,
        qualifier: String? = nil,
        primary: Bool = false,
        scope: ServiceContainer.Scope = .singleton,
        dependsOn: [Dependency] = [],
        factory: @escaping @Sendable (ServiceResolver) throws -> T
    ) async throws {
        try await container.override(
            type,
            qualifier: qualifier,
            primary: primary,
            scope: scope,
            dependsOn: dependsOn,
            factory: factory
        )
    }

    public func override<T: Sendable>(
        _ type: T.Type = T.self,
        qualifier: String? = nil,
        primary: Bool = false,
        scope: ServiceContainer.Scope = .singleton,
        dependsOn: [Dependency] = [],
        factory: @escaping @Sendable (ServiceResolver) async throws -> T
    ) async throws {
        try await container.override(
            type,
            qualifier: qualifier,
            primary: primary,
            scope: scope,
            dependsOn: dependsOn,
            factory: factory
        )
    }

    public func graphSnapshot() async throws -> GraphSnapshot {
        try await container.validateGraph()
    }
}

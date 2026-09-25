import Foundation
import PearfyCore

private struct RequestScopeKey: Hashable, Sendable {
    let typeID: ObjectIdentifier
    let qualifier: String?
}

/// A type-safe dependency key. Protocol existential types can be registered directly.
public struct Dependency: Hashable, Sendable {
    fileprivate let typeID: ObjectIdentifier
    public let typeName: String
    public let qualifier: String?

    public init<T>(_ type: T.Type, qualifier: String? = nil) {
        typeID = ObjectIdentifier(type)
        typeName = String(reflecting: type)
        self.qualifier = qualifier
    }
}

/// Metadata-only view of a validated object graph.
public struct GraphSnapshot: Sendable, Equatable {
    public struct Edge: Sendable, Equatable {
        public let consumer: String
        public let dependency: String
    }

    public let registrations: [String]
    public let edges: [Edge]
}

/// A scoped resolver passed to factories. Child resolvers carry the current path
/// so direct and indirect cycles produce a complete diagnostic.
public struct ServiceResolver: Sendable {
    private let resolveValue: @Sendable (Any.Type, String?) async throws -> any Sendable

    fileprivate init(resolveValue: @escaping @Sendable (Any.Type, String?) async throws -> any Sendable) {
        self.resolveValue = resolveValue
    }

    public func resolve<T: Sendable>(_ type: T.Type = T.self, qualifier: String? = nil) async throws -> T {
        let value = try await resolveValue(type, qualifier)
        guard let result = value as? T else {
            throw ServiceContainer.ResolutionError.typeMismatch(String(reflecting: type))
        }
        return result
    }
}

/// Concurrent DI container. Actor isolation protects metadata and caches; no
/// lock is held while an asynchronous factory is running.
public actor ServiceContainer {
    public enum Scope: Sendable, Equatable {
        case singleton
        case transient
        case request
    }

    public enum ResolutionError: Error, Sendable, Equatable, CustomStringConvertible {
        case missingComponent(type: String, qualifier: String?)
        case ambiguousComponent(type: String, candidates: [String])
        case circularDependency(path: [String])
        case scopeMismatch(consumer: String, dependency: String)
        case requestScopeUnavailable(String)
        case requestScopeClosed
        case typeMismatch(String)
        case duplicateRegistration(type: String, qualifier: String?)
        case containerFrozen
        case invalidGraph(String)
        case factoryFailed(type: String, cause: String)

        public var code: String {
            switch self {
            case .missingComponent: "PEARFY_DI_001"
            case .ambiguousComponent: "PEARFY_DI_002"
            case .circularDependency: "PEARFY_DI_003"
            case .scopeMismatch, .requestScopeUnavailable, .requestScopeClosed: "PEARFY_DI_004"
            case .typeMismatch, .duplicateRegistration, .containerFrozen, .invalidGraph: "PEARFY_DI_007"
            case .factoryFailed: "PEARFY_DI_005"
            }
        }

        public var diagnostic: PearfyDiagnostic {
            let prefix = "\(code): "
            let message = description.hasPrefix(prefix) ? String(description.dropFirst(prefix.count)) : description
            return PearfyDiagnostic(code: code, message: message)
        }

        public var description: String {
            switch self {
            case .missingComponent(let type, let qualifier):
                let selection = qualifier.map { " with qualifier '\($0)'" } ?? ""
                return "\(code): no registration for \(type)\(selection)"
            case .ambiguousComponent(let type, let candidates):
                return "\(code): multiple registrations for \(type): \(candidates.joined(separator: ", "))"
            case .circularDependency(let path):
                return "\(code): circular dependency: \(path.joined(separator: " -> "))"
            case .scopeMismatch(let consumer, let dependency):
                return "\(code): singleton \(consumer) cannot depend on request-scoped \(dependency)"
            case .requestScopeUnavailable(let type):
                return "\(code): resolving request-scoped \(type) requires an explicit request scope"
            case .requestScopeClosed:
                return "\(code): request scope has already been closed"
            case .typeMismatch(let type):
                return "\(code): factory produced a value of the wrong type for \(type)"
            case .duplicateRegistration(let type, let qualifier):
                return "\(code): duplicate registration for \(type) (qualifier: \(qualifier ?? "<none>"))"
            case .containerFrozen:
                return "\(code): registrations cannot change after the application context is frozen"
            case .invalidGraph(let message):
                return "\(code): invalid dependency graph: \(message)"
            case .factoryFailed(let type, let cause):
                return "\(code): factory for \(type) failed: \(cause)"
            }
        }
    }

    private struct Key: Hashable, Sendable {
        let typeID: ObjectIdentifier
        let typeName: String
        let qualifier: String?

        init(_ dependency: Dependency) {
            typeID = dependency.typeID
            typeName = dependency.typeName
            qualifier = dependency.qualifier
        }

        var displayName: String {
            guard let qualifier else { return typeName }
            return "\(typeName)[\(qualifier)]"
        }
    }

    private struct Registration: Sendable {
        let key: Key
        let scope: Scope
        let isPrimary: Bool
        let dependencies: [Dependency]
        let factory: @Sendable (ServiceResolver) async throws -> any Sendable
    }

    private struct InFlight: Sendable {
        let id: UUID
        let task: Task<any Sendable, Error>
    }

    private var registrations: [Key: Registration] = [:]
    private var registrationKeysByType: [ObjectIdentifier: [Key]] = [:]
    private var defaultRegistrationByType: [ObjectIdentifier: Key] = [:]
    private var primaryRegistrationByType: [ObjectIdentifier: Key] = [:]
    private var primaryRegistrationCounts: [ObjectIdentifier: Int] = [:]
    private var singletons: [Key: any Sendable] = [:]
    private var inFlight: [Key: InFlight] = [:]
    private var graphSnapshotCache: GraphSnapshot?
    private var frozen = false

    public init() {}

    /// Registers a synchronous factory. Duplicate type/qualifier pairs are rejected.
    public func register<T: Sendable>(
        _ type: T.Type = T.self,
        qualifier: String? = nil,
        primary: Bool = false,
        scope: Scope = .singleton,
        dependsOn: [Dependency] = [],
        factory: @escaping @Sendable (ServiceResolver) throws -> T
    ) throws {
        try addRegistration(
            type,
            qualifier: qualifier,
            primary: primary,
            scope: scope,
            dependsOn: dependsOn,
            factory: { resolver in try factory(resolver) }
        )
    }

    /// Registers an asynchronous factory. Concurrent singleton resolutions share
    /// the same in-flight task, including its success or failure.
    public func register<T: Sendable>(
        _ type: T.Type = T.self,
        qualifier: String? = nil,
        primary: Bool = false,
        scope: Scope = .singleton,
        dependsOn: [Dependency] = [],
        factory: @escaping @Sendable (ServiceResolver) async throws -> T
    ) throws {
        try addRegistration(
            type,
            qualifier: qualifier,
            primary: primary,
            scope: scope,
            dependsOn: dependsOn,
            factory: { resolver in try await factory(resolver) }
        )
    }

    /// Explicitly replaces a registration in this container and clears its cache.
    /// Intended for isolated test contexts and deliberate environment overrides.
    public func override<T: Sendable>(
        _ type: T.Type = T.self,
        qualifier: String? = nil,
        primary: Bool = false,
        scope: Scope = .singleton,
        dependsOn: [Dependency] = [],
        factory: @escaping @Sendable (ServiceResolver) throws -> T
    ) throws {
        try replaceRegistration(
            type,
            qualifier: qualifier,
            primary: primary,
            scope: scope,
            dependsOn: dependsOn,
            factory: { resolver in try factory(resolver) }
        )
    }

    public func override<T: Sendable>(
        _ type: T.Type = T.self,
        qualifier: String? = nil,
        primary: Bool = false,
        scope: Scope = .singleton,
        dependsOn: [Dependency] = [],
        factory: @escaping @Sendable (ServiceResolver) async throws -> T
    ) throws {
        try replaceRegistration(
            type,
            qualifier: qualifier,
            primary: primary,
            scope: scope,
            dependsOn: dependsOn,
            factory: { resolver in try await factory(resolver) }
        )
    }

    public func resolve<T: Sendable>(_ type: T.Type = T.self, qualifier: String? = nil) async throws -> T {
        let value = try await resolveValue(type, qualifier: qualifier, path: [])
        guard let result = value as? T else {
            throw ResolutionError.typeMismatch(String(reflecting: type))
        }
        return result
    }

    public func makeRequestScope() -> ServiceRequestScope {
        ServiceRequestScope(container: self)
    }

    fileprivate func resolveInRequestScope(
        _ type: Any.Type,
        qualifier: String?,
        scope: ServiceRequestScope
    ) async throws -> any Sendable {
        try await resolveValue(type, qualifier: qualifier, path: [], requestScope: scope)
    }

    /// Validates all declared edges before application startup and returns a stable snapshot.
    public func validateGraph() throws -> GraphSnapshot {
        if let graphSnapshotCache { return graphSnapshotCache }
        let ordered = registrations.values.sorted { $0.key.displayName < $1.key.displayName }
        var adjacency: [Key: [Key]] = [:]
        var edges: [GraphSnapshot.Edge] = []

        for registration in ordered {
            var resolvedDependencies: [Key] = []
            for dependency in registration.dependencies {
                let target = try selectRegistration(for: Key(dependency))
                if registration.scope == .singleton && target.scope == .request {
                    throw ResolutionError.scopeMismatch(
                        consumer: registration.key.displayName,
                        dependency: target.key.displayName
                    )
                }
                resolvedDependencies.append(target.key)
                edges.append(.init(consumer: registration.key.displayName, dependency: target.key.displayName))
            }
            adjacency[registration.key] = resolvedDependencies
        }

        var visited: Set<Key> = []
        var active: [Key] = []
        func visit(_ key: Key) throws {
            if let cycleStart = active.firstIndex(of: key) {
                let path = Array(active[cycleStart...]).map(\.displayName) + [key.displayName]
                throw ResolutionError.circularDependency(path: path)
            }
            guard visited.insert(key).inserted else { return }
            active.append(key)
            for dependency in adjacency[key, default: []] {
                try visit(dependency)
            }
            active.removeLast()
        }

        for registration in ordered {
            try visit(registration.key)
        }
        let snapshot = GraphSnapshot(
            registrations: ordered.map { $0.key.displayName },
            edges: edges.sorted {
                ($0.consumer, $0.dependency) < ($1.consumer, $1.dependency)
            }
        )
        graphSnapshotCache = snapshot
        return snapshot
    }

    /// Validates the complete graph and prevents any later registry mutation.
    /// ApplicationContext freezes before starting lifecycle components.
    public func freeze() throws -> GraphSnapshot {
        let snapshot = try validateGraph()
        frozen = true
        return snapshot
    }

    public func isFrozen() -> Bool {
        frozen
    }

    /// Creates a new container with the same definitions but no cached instances.
    public func isolatedCopy() async -> ServiceContainer {
        let copy = ServiceContainer()
        await copy.importRegistrations(Array(registrations.values))
        return copy
    }

    private func importRegistrations(_ values: [Registration]) {
        registrations = Dictionary(uniqueKeysWithValues: values.map { ($0.key, $0) })
        registrationKeysByType.removeAll(keepingCapacity: true)
        defaultRegistrationByType.removeAll(keepingCapacity: true)
        primaryRegistrationByType.removeAll(keepingCapacity: true)
        primaryRegistrationCounts.removeAll(keepingCapacity: true)
        for registration in values {
            registrationKeysByType[registration.key.typeID, default: []].append(registration.key)
        }
        for typeID in registrationKeysByType.keys {
            refreshDefaultRegistration(for: typeID)
        }
    }

    private func addRegistration<T: Sendable>(
        _ type: T.Type,
        qualifier: String?,
        primary: Bool,
        scope: Scope,
        dependsOn: [Dependency],
        factory: @escaping @Sendable (ServiceResolver) async throws -> any Sendable
    ) throws {
        guard !frozen else { throw ResolutionError.containerFrozen }
        let key = Key(Dependency(type, qualifier: qualifier))
        guard registrations[key] == nil else {
            throw ResolutionError.duplicateRegistration(type: key.typeName, qualifier: qualifier)
        }
        let registration = Registration(
            key: key,
            scope: scope,
            isPrimary: primary,
            dependencies: dependsOn,
            factory: factory
        )
        registrations[key] = registration
        indexNewRegistration(registration)
        singletons.removeValue(forKey: key)
        graphSnapshotCache = nil
    }

    private func replaceRegistration<T: Sendable>(
        _ type: T.Type,
        qualifier: String?,
        primary: Bool,
        scope: Scope,
        dependsOn: [Dependency],
        factory: @escaping @Sendable (ServiceResolver) async throws -> any Sendable
    ) throws {
        guard !frozen else { throw ResolutionError.containerFrozen }
        let key = Key(Dependency(type, qualifier: qualifier))
        registrations[key] = Registration(
            key: key,
            scope: scope,
            isPrimary: primary,
            dependencies: dependsOn,
            factory: factory
        )
        refreshDefaultRegistration(for: key.typeID)
        singletons.removeValue(forKey: key)
        inFlight.removeValue(forKey: key)?.task.cancel()
        graphSnapshotCache = nil
    }

    private func selectRegistration(for requested: Key) throws -> Registration {
        if let qualifier = requested.qualifier {
            guard let match = registrations[requested] else {
                throw ResolutionError.missingComponent(type: requested.typeName, qualifier: qualifier)
            }
            return match
        }

        if let key = defaultRegistrationByType[requested.typeID],
           let registration = registrations[key] {
            return registration
        }

        let keys = registrationKeysByType[requested.typeID, default: []]
        guard !keys.isEmpty else {
            throw ResolutionError.missingComponent(type: requested.typeName, qualifier: nil)
        }
        let candidates = keys.compactMap { registrations[$0] }
        let primary = candidates.filter(\.isPrimary)
        let orderedCandidates = candidates.sorted { $0.key.displayName < $1.key.displayName }
        if primary.count == 1 { return primary[0] }
        throw ResolutionError.ambiguousComponent(
            type: requested.typeName,
            candidates: orderedCandidates.map(\.key.displayName)
        )
    }

    private func indexNewRegistration(_ registration: Registration) {
        let key = registration.key
        let existingCount = registrationKeysByType[key.typeID, default: []].count
        registrationKeysByType[key.typeID, default: []].append(key)

        if registration.isPrimary {
            let primaryCount = primaryRegistrationCounts[key.typeID, default: 0] + 1
            primaryRegistrationCounts[key.typeID] = primaryCount
            if primaryCount == 1 {
                primaryRegistrationByType[key.typeID] = key
                defaultRegistrationByType[key.typeID] = key
            } else {
                primaryRegistrationByType.removeValue(forKey: key.typeID)
                defaultRegistrationByType.removeValue(forKey: key.typeID)
            }
        } else if existingCount == 0 {
            defaultRegistrationByType[key.typeID] = key
        } else if let primaryKey = primaryRegistrationByType[key.typeID],
                  primaryRegistrationCounts[key.typeID] == 1 {
            defaultRegistrationByType[key.typeID] = primaryKey
        } else {
            defaultRegistrationByType.removeValue(forKey: key.typeID)
        }
    }

    private func refreshDefaultRegistration(for typeID: ObjectIdentifier) {
        let candidates = registrationKeysByType[typeID, default: []].compactMap { registrations[$0] }
        let primary = candidates.filter(\.isPrimary)
        primaryRegistrationCounts[typeID] = primary.count
        if primary.count == 1 {
            primaryRegistrationByType[typeID] = primary[0].key
            defaultRegistrationByType[typeID] = primary[0].key
        } else {
            primaryRegistrationByType.removeValue(forKey: typeID)
            if candidates.count == 1 {
                defaultRegistrationByType[typeID] = candidates[0].key
                return
            }
            defaultRegistrationByType.removeValue(forKey: typeID)
        }
    }

    private func resolveValue(
        _ type: Any.Type,
        qualifier: String?,
        path: [Key],
        requestScope: ServiceRequestScope? = nil
    ) async throws -> any Sendable {
        try Task.checkCancellation()
        let requested = Key(Dependency(type, qualifier: qualifier))
        let registration = try selectRegistration(for: requested)
        let key = registration.key

        if let instance = singletons[key] { return instance }
        if registration.scope == .request, let requestScope,
           let instance = await requestScope.cached(RequestScopeKey(typeID: key.typeID, qualifier: key.qualifier)) {
            return instance
        }
        if let cycleStart = path.firstIndex(of: key) {
            let cycle = Array(path[cycleStart...]).map(\.displayName) + [key.displayName]
            throw ResolutionError.circularDependency(path: cycle)
        }

        let nextPath = path + [key]
        let resolver = ServiceResolver { [weak self] dependencyType, dependencyQualifier in
            guard let self else {
                throw ResolutionError.invalidGraph("resolver outlived its service container")
            }
            return try await self.resolveValue(
                dependencyType,
                qualifier: dependencyQualifier,
                path: nextPath,
                requestScope: requestScope
            )
        }

        switch registration.scope {
        case .transient:
            do {
                let instance = try await registration.factory(resolver)
                try Task.checkCancellation()
                return instance
            } catch let error as ResolutionError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ResolutionError.factoryFailed(type: key.typeName, cause: String(describing: error))
            }
        case .singleton:
            let pending: InFlight
            if let existing = inFlight[key] {
                pending = existing
            } else {
                let created = InFlight(
                    id: UUID(),
                    task: Task { try await registration.factory(resolver) }
                )
                inFlight[key] = created
                pending = created
            }

            do {
                let instance = try await pending.task.value
                if inFlight[key]?.id == pending.id {
                    singletons[key] = instance
                    inFlight.removeValue(forKey: key)
                }
                try Task.checkCancellation()
                return instance
            } catch let error as ResolutionError {
                if inFlight[key]?.id == pending.id { inFlight.removeValue(forKey: key) }
                throw error
            } catch is CancellationError {
                if inFlight[key]?.id == pending.id { inFlight.removeValue(forKey: key) }
                throw CancellationError()
            } catch {
                if inFlight[key]?.id == pending.id { inFlight.removeValue(forKey: key) }
                throw ResolutionError.factoryFailed(type: key.typeName, cause: String(describing: error))
            }
        case .request:
            guard let requestScope else { throw ResolutionError.requestScopeUnavailable(key.typeName) }
            return try await requestScope.resolveInstance(
                RequestScopeKey(typeID: key.typeID, qualifier: key.qualifier),
                typeName: key.typeName,
                factory: { try await registration.factory(resolver) }
            )
        }
    }
}

/// Per-request object cache. Create one for a request and call `close()` during
/// teardown so request data cannot leak into later requests.
public actor ServiceRequestScope {
    private struct InFlight {
        let id: UUID
        let task: Task<any Sendable, Error>
    }

    private let container: ServiceContainer
    private var instances: [RequestScopeKey: any Sendable] = [:]
    private var inFlight: [RequestScopeKey: InFlight] = [:]
    private var closed = false

    fileprivate init(container: ServiceContainer) {
        self.container = container
    }

    public func resolve<T: Sendable>(_ type: T.Type = T.self, qualifier: String? = nil) async throws -> T {
        guard !closed else { throw ServiceContainer.ResolutionError.requestScopeClosed }
        let value = try await container.resolveInRequestScope(type, qualifier: qualifier, scope: self)
        guard let result = value as? T else {
            throw ServiceContainer.ResolutionError.typeMismatch(String(reflecting: type))
        }
        return result
    }

    public func close() {
        guard !closed else { return }
        closed = true
        for pending in inFlight.values { pending.task.cancel() }
        inFlight.removeAll()
        instances.removeAll()
    }

    fileprivate func cached(_ key: RequestScopeKey) -> (any Sendable)? {
        guard !closed else { return nil }
        return instances[key]
    }

    fileprivate func resolveInstance(
        _ key: RequestScopeKey,
        typeName: String,
        factory: @escaping @Sendable () async throws -> any Sendable
    ) async throws -> any Sendable {
        guard !closed else { throw ServiceContainer.ResolutionError.requestScopeClosed }
        if let instance = instances[key] { return instance }

        let pending: InFlight
        if let existing = inFlight[key] {
            pending = existing
        } else {
            let created = InFlight(id: UUID(), task: Task { try await factory() })
            inFlight[key] = created
            pending = created
        }

        do {
            let instance = try await pending.task.value
            if inFlight[key]?.id == pending.id {
                instances[key] = instance
                inFlight.removeValue(forKey: key)
            }
            try Task.checkCancellation()
            return instance
        } catch let error as ServiceContainer.ResolutionError {
            if inFlight[key]?.id == pending.id { inFlight.removeValue(forKey: key) }
            throw error
        } catch is CancellationError {
            if inFlight[key]?.id == pending.id { inFlight.removeValue(forKey: key) }
            throw CancellationError()
        } catch {
            if inFlight[key]?.id == pending.id { inFlight.removeValue(forKey: key) }
            throw ServiceContainer.ResolutionError.factoryFailed(type: typeName, cause: String(describing: error))
        }
    }
}

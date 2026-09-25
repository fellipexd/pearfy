import Foundation

/// Small synchronous DI prototype. Register dependencies in the composition root.
public final class ServiceContainer: @unchecked Sendable {
    public enum Scope: Sendable {
        case singleton
        case transient
    }

    public enum ResolutionError: Error, Sendable, Equatable, CustomStringConvertible {
        case notRegistered(String)
        case circularDependency(String)
        case typeMismatch(String)

        public var description: String {
            switch self {
            case .notRegistered(let type): return "No registration for \(type)"
            case .circularDependency(let type): return "Circular dependency while resolving \(type)"
            case .typeMismatch(let type): return "Factory produced wrong type for \(type)"
            }
        }
    }

    private struct Registration {
        let scope: Scope
        let factory: @Sendable (ServiceContainer) throws -> any Sendable
    }

    // Recursive mutex supports nested synchronous factories in this prototype.
    // Async factories and request scopes require a redesigned concurrency model.
    private let lock = NSRecursiveLock()
    private var registrations: [ObjectIdentifier: Registration] = [:]
    private var singletons: [ObjectIdentifier: any Sendable] = [:]
    private var resolving: Set<ObjectIdentifier> = []

    public init() {}

    public func register<T: Sendable>(
        _ type: T.Type = T.self,
        scope: Scope = .singleton,
        factory: @escaping @Sendable (ServiceContainer) throws -> T
    ) {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(type)
        registrations[key] = Registration(scope: scope, factory: { try factory($0) })
        singletons.removeValue(forKey: key)
    }

    public func resolve<T: Sendable>(_ type: T.Type = T.self) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(type)
        let typeName = String(reflecting: type)

        if let instance = singletons[key] {
            guard let typed = instance as? T else {
                throw ResolutionError.typeMismatch(typeName)
            }
            return typed
        }
        guard let registration = registrations[key] else {
            throw ResolutionError.notRegistered(typeName)
        }
        guard !resolving.contains(key) else {
            throw ResolutionError.circularDependency(typeName)
        }

        resolving.insert(key)
        defer { resolving.remove(key) }
        let instance = try registration.factory(self)
        guard let typed = instance as? T else {
            throw ResolutionError.typeMismatch(typeName)
        }
        if registration.scope == .singleton {
            singletons[key] = typed
        }
        return typed
    }
}

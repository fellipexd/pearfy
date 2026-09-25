import PearfyConfiguration
import PearfyDI

public protocol ApplicationLifecycle: Sendable {
    var name: String { get }
    func start() async throws
    func stop() async throws
}

public actor ApplicationContext {
    public enum State: String, Sendable, Equatable {
        case initialized
        case starting
        case running
        case stopping
        case stopped
        case failed
    }

    public enum ContextError: Error, Sendable, Equatable, CustomStringConvertible {
        case invalidState(expected: String, actual: State)
        case startupFailed(component: String, cause: String)
        case shutdownFailed(components: [String])

        public var description: String {
            switch self {
            case .invalidState(let expected, let actual):
                "PEARFY_CONTEXT_001: expected state \(expected), found \(actual.rawValue)"
            case .startupFailed(let component, let cause):
                "PEARFY_DI_006: startup of \(component) failed: \(cause)"
            case .shutdownFailed(let components):
                "PEARFY_DI_006: shutdown failed for \(components.joined(separator: ", "))"
            }
        }
    }

    public let container: ServiceContainer
    public let configuration: Configuration
    public let profiles: [String]

    private let lifecycleComponents: [any ApplicationLifecycle]
    private var startedComponents: [any ApplicationLifecycle] = []
    private(set) public var state: State = .initialized

    public init(
        container: ServiceContainer = ServiceContainer(),
        configuration: Configuration,
        lifecycle: [any ApplicationLifecycle] = []
    ) {
        self.container = container
        self.configuration = configuration
        self.profiles = configuration.profiles
        self.lifecycleComponents = lifecycle
    }

    /// Validates the dependency graph before starting any component. If a start
    /// fails, already-started components are stopped in reverse order.
    public func start() async throws {
        guard state == .initialized else {
            throw ContextError.invalidState(expected: State.initialized.rawValue, actual: state)
        }
        state = .starting

        do {
            _ = try await container.freeze()
        } catch {
            state = .failed
            throw error
        }

        for component in lifecycleComponents {
            do {
                try await component.start()
                startedComponents.append(component)
            } catch {
                var rollbackFailures: [String] = []
                for started in startedComponents.reversed() {
                    do {
                        try await started.stop()
                    } catch {
                        rollbackFailures.append("\(started.name): \(error)")
                    }
                }
                startedComponents.removeAll()
                state = .failed
                let rollbackDetails = rollbackFailures.isEmpty
                    ? ""
                    : "; rollback failures: \(rollbackFailures.joined(separator: ", "))"
                throw ContextError.startupFailed(
                    component: component.name,
                    cause: "\(error)\(rollbackDetails)"
                )
            }
        }
        state = .running
    }

    /// Stops all started components in reverse startup order, attempting every stop.
    public func stop() async throws {
        guard state == .running else {
            if state == .stopped { return }
            throw ContextError.invalidState(expected: State.running.rawValue, actual: state)
        }
        state = .stopping
        var failures: [String] = []
        for component in startedComponents.reversed() {
            do {
                try await component.stop()
            } catch {
                failures.append("\(component.name): \(error)")
            }
        }
        startedComponents.removeAll()
        state = .stopped
        if !failures.isEmpty {
            throw ContextError.shutdownFailed(components: failures)
        }
    }
}

import Foundation
import PearfyConfiguration
import PearfyContext
import PearfyDI
import PearfyTesting
import Testing

@Test func singletonReturnsSameInstance() async throws {
    let container = ServiceContainer()
    try await container.register(Token.self) { _ in Token("same") }
    let first = try await container.resolve(Token.self)
    let second = try await container.resolve(Token.self)
    #expect(first === second)
}

@Test func transientReturnsDistinctInstances() async throws {
    let container = ServiceContainer()
    try await container.register(Token.self, scope: .transient) { _ in Token("new") }
    let first = try await container.resolve(Token.self)
    let second = try await container.resolve(Token.self)
    #expect(first !== second)
}

@Test func missingServiceHasStableDiagnostic() async throws {
    let container = ServiceContainer()
    var resolutionError: ServiceContainer.ResolutionError?
    do {
        _ = try await container.resolve(Token.self)
    } catch let error as ServiceContainer.ResolutionError {
        resolutionError = error
    }
    #expect(resolutionError?.code == "PEARFY_DI_001")
}

@Test func graphValidationDiagnosesMissingDependenciesBeforeStartup() async throws {
    let container = ServiceContainer()
    try await container.register(CycleA.self, dependsOn: [Dependency(CycleB.self)]) { _ in CycleA() }

    var resolutionError: ServiceContainer.ResolutionError?
    do {
        _ = try await container.validateGraph()
    } catch let error as ServiceContainer.ResolutionError {
        resolutionError = error
    }
    #expect(resolutionError?.code == "PEARFY_DI_001")
}

@Test func requestScopeCachesPerRequestAndReleasesValuesOnClose() async throws {
    let container = ServiceContainer()
    let counter = FactoryCounter()
    try await container.register(RequestScopedValue.self, scope: .request) { _ in
        await counter.increment()
        try await Task.sleep(for: .milliseconds(10))
        return RequestScopedValue(id: UUID())
    }

    let firstScope = await container.makeRequestScope()
    let firstResults = try await withThrowingTaskGroup(of: UUID.self) { group in
        for _ in 0..<30 {
            group.addTask { try await firstScope.resolve(RequestScopedValue.self).id }
        }
        var identifiers: [UUID] = []
        for try await id in group { identifiers.append(id) }
        return identifiers
    }
    #expect(Set(firstResults).count == 1)
    let firstFactoryCalls = await counter.value
    #expect(firstFactoryCalls == 1)

    let secondScope = await container.makeRequestScope()
    let secondValue = try await secondScope.resolve(RequestScopedValue.self)
    #expect(secondValue.id != firstResults[0])
    await firstScope.close()
    await secondScope.close()

    var closedScopeError: ServiceContainer.ResolutionError?
    do {
        _ = try await firstScope.resolve(RequestScopedValue.self)
    } catch let error as ServiceContainer.ResolutionError {
        closedScopeError = error
    }
    #expect(closedScopeError?.code == "PEARFY_DI_004")

    var missingScopeError: ServiceContainer.ResolutionError?
    do {
        _ = try await container.resolve(RequestScopedValue.self)
    } catch let error as ServiceContainer.ResolutionError {
        missingScopeError = error
    }
    #expect(missingScopeError?.code == "PEARFY_DI_004")
}

@Test func closingRequestScopeReleasesCachedReferenceValues() async throws {
    let container = ServiceContainer()
    try await container.register(RequestScopedReference.self, scope: .request) { _ in RequestScopedReference() }
    let scope = await container.makeRequestScope()
    weak var cachedReference: RequestScopedReference?
    cachedReference = try await scope.resolve(RequestScopedReference.self)
    #expect(cachedReference != nil)

    await scope.close()
    #expect(cachedReference == nil)
}

@Test func singletonCannotCaptureRequestScopedDependency() async throws {
    let container = ServiceContainer()
    try await container.register(RequestScopedValue.self, scope: .request) { _ in
        RequestScopedValue(id: UUID())
    }
    try await container.register(
        SingletonRequestConsumer.self,
        dependsOn: [Dependency(RequestScopedValue.self)]
    ) { resolver in
        SingletonRequestConsumer(value: try await resolver.resolve(RequestScopedValue.self))
    }

    var resolutionError: ServiceContainer.ResolutionError?
    do {
        _ = try await container.validateGraph()
    } catch let error as ServiceContainer.ResolutionError {
        resolutionError = error
    }
    #expect(resolutionError?.code == "PEARFY_DI_004")
}

@Test func directAndIndirectCyclesIncludeThePath() async throws {
    let direct = ServiceContainer()
    try await direct.register(Int.self) { resolver in
        try await resolver.resolve(Int.self)
    }
    var directError: ServiceContainer.ResolutionError?
    do {
        _ = try await direct.resolve(Int.self)
    } catch let error as ServiceContainer.ResolutionError {
        directError = error
    }
    if case .circularDependency(let path)? = directError {
        #expect(path == ["Swift.Int", "Swift.Int"])
    } else {
        Issue.record("Expected a direct-cycle error, got \(String(describing: directError))")
    }

    let indirect = ServiceContainer()
    try await indirect.register(CycleA.self, dependsOn: [Dependency(CycleB.self)]) { _ in CycleA() }
    try await indirect.register(CycleB.self, dependsOn: [Dependency(CycleA.self)]) { _ in CycleB() }
    var indirectError: ServiceContainer.ResolutionError?
    do {
        _ = try await indirect.validateGraph()
    } catch let error as ServiceContainer.ResolutionError {
        indirectError = error
    }
    if case .circularDependency(let path)? = indirectError {
        #expect(path.count == 3)
        #expect(path.first == path.last)
    } else {
        Issue.record("Expected an indirect-cycle error, got \(String(describing: indirectError))")
    }
}

@Test func protocolBindingAndQualifierPrimarySelection() async throws {
    let container = ServiceContainer()
    try await container.register((any Greeter).self, qualifier: "friendly") { _ in FriendlyGreeter() }
    try await container.register(
        (any Greeter).self,
        qualifier: "formal",
        primary: true
    ) { _ in FormalGreeter() }

    let selected = try await container.resolve((any Greeter).self)
    let qualified = try await container.resolve((any Greeter).self, qualifier: "friendly")
    #expect(selected.greeting == "Good day")
    #expect(qualified.greeting == "Hello")
}

@Test func ambiguousBindingsAreDiagnosed() async throws {
    let container = ServiceContainer()
    try await container.register((any Greeter).self, qualifier: "one") { _ in FriendlyGreeter() }
    try await container.register((any Greeter).self, qualifier: "two") { _ in FormalGreeter() }
    try await container.register(CycleA.self, dependsOn: [Dependency((any Greeter).self)]) { _ in CycleA() }
    var resolutionError: ServiceContainer.ResolutionError?
    do {
        _ = try await container.resolve((any Greeter).self)
    } catch let error as ServiceContainer.ResolutionError {
        resolutionError = error
    }
    #expect(resolutionError?.code == "PEARFY_DI_002")

    resolutionError = nil
    do {
        _ = try await container.validateGraph()
    } catch let error as ServiceContainer.ResolutionError {
        resolutionError = error
    }
    #expect(resolutionError?.code == "PEARFY_DI_002")
}

@Test func indexedQualifierAndPrimaryLookupSelectsAmongManyRegistrations() async throws {
    let container = ServiceContainer()
    for index in 0..<1_000 {
        try await container.register(
            (any Greeter).self,
            qualifier: "provider-\(index)",
            primary: index == 999
        ) { _ in NumberedGreeter(greeting: "provider-\(index)") }
    }

    let primary = try await container.resolve((any Greeter).self)
    let qualified = try await container.resolve((any Greeter).self, qualifier: "provider-500")
    #expect(primary.greeting == "provider-999")
    #expect(qualified.greeting == "provider-500")
}

@Test func concurrentAsyncSingletonFactoryRunsOnce() async throws {
    let container = ServiceContainer()
    let counter = FactoryCounter()
    try await container.register(Token.self) { _ async throws in
        await counter.increment()
        try await Task.sleep(for: .milliseconds(15))
        return Token("shared")
    }

    let instances = try await withThrowingTaskGroup(of: Token.self) { group in
        for _ in 0..<100 {
            group.addTask { try await container.resolve(Token.self) }
        }
        var values: [Token] = []
        for try await value in group { values.append(value) }
        return values
    }
    let factoryCount = await counter.value
    #expect(factoryCount == 1)
    #expect(instances.count == 100)
    #expect(instances.allSatisfy { $0 === instances[0] })
}

@Test func factoryCancellationRemainsCancellation() async throws {
    let container = ServiceContainer()
    let counter = FactoryCounter()
    try await container.register(Token.self) { _ async throws in
        await counter.increment()
        try await Task.sleep(for: .milliseconds(15))
        throw CancellationError()
    }

    let cancelled = try await withThrowingTaskGroup(of: Bool.self) { group in
        for _ in 0..<100 {
            group.addTask {
                do {
                    _ = try await container.resolve(Token.self)
                    return false
                } catch is CancellationError {
                    return true
                }
            }
        }
        var results: [Bool] = []
        for try await result in group { results.append(result) }
        return results
    }
    let factoryCalls = await counter.value
    #expect(cancelled.count == 100)
    #expect(cancelled.allSatisfy { $0 })
    #expect(factoryCalls == 1)
}

@Test func failedSingletonFactoryWakesAllWaitersAndCanRetry() async throws {
    let container = ServiceContainer()
    let counter = FactoryCounter()
    try await container.register(Token.self) { _ async throws in
        await counter.increment()
        try await Task.sleep(for: .milliseconds(20))
        throw FactoryTestError.failed
    }

    let errorCodes = try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<100 {
            group.addTask {
                do {
                    _ = try await container.resolve(Token.self)
                    return "unexpected-success"
                } catch let error as ServiceContainer.ResolutionError {
                    return error.code
                }
            }
        }
        var values: [String] = []
        for try await value in group { values.append(value) }
        return values
    }
    #expect(errorCodes.allSatisfy { $0 == "PEARFY_DI_005" })
    let initialFactoryCalls = await counter.value
    #expect(initialFactoryCalls == 1)

    do {
        _ = try await container.resolve(Token.self)
    } catch let error as ServiceContainer.ResolutionError {
        #expect(error.code == "PEARFY_DI_005")
    }
    let retryFactoryCalls = await counter.value
    #expect(retryFactoryCalls == 2)
}

@Test func testContextOverridesAreIsolatedFromBaseAndOtherTests() async throws {
    let production = ServiceContainer()
    try await production.register(Token.self) { _ in Token("production") }
    let productionInstance = try await production.resolve(Token.self)

    let firstTest = await TestContext(copying: production)
    let secondTest = await TestContext(copying: production)
    try await firstTest.override(Token.self) { _ in Token("mock") }

    let mockValue = try await firstTest.container.resolve(Token.self).value
    let isolatedValue = try await secondTest.container.resolve(Token.self).value
    let originalInstance = try await production.resolve(Token.self)
    #expect(mockValue == "mock")
    #expect(isolatedValue == "production")
    #expect(originalInstance === productionInstance)
}

@Test func configurationPrecedenceProfilesTypingAndSecretRedaction() throws {
    let configuration = try ConfigurationLoader.load(
        defaults: ["server.port": "8080", "database.password": "default"],
        fileContents: "server.port=9000\nprofile.dev.server.port=9001\nprofile.dev.feature.enabled=true\n",
        environment: ["PEARFY_SERVER_PORT": "9100", "PEARFY_DATABASE_PASSWORD": "env"],
        arguments: ["--server.port=9200"],
        activeProfiles: ["dev"]
    )

    #expect(try configuration.value(forKey: "server.port", as: Int.self) == 9200)
    #expect(try configuration.bool(forKey: "feature.enabled"))
    #expect(configuration.source(forKey: "server.port") == .commandLine)
    #expect(configuration.redactedValues["database.password"] == "[REDACTED]")

    let invalidSecret = ConfigurationError.invalidValue(key: "database.password", value: "sensitive-value", expected: "Int")
    #expect(!invalidSecret.description.contains("sensitive-value"))
}

@Test func lifecycleStartsInOrderAndStopsInReverse() async throws {
    let recorder = LifecycleRecorder()
    let config = try ConfigurationLoader.load()
    let context = ApplicationContext(
        configuration: config,
        lifecycle: [
            RecordedLifecycle(name: "database", recorder: recorder),
            RecordedLifecycle(name: "http", recorder: recorder)
        ]
    )

    try await context.start()
    let runningState = await context.state
    #expect(runningState == .running)
    try await context.stop()
    let events = await recorder.events
    let stoppedState = await context.state
    #expect(events == ["start:database", "start:http", "stop:http", "stop:database"])
    #expect(stoppedState == .stopped)
}

@Test func applicationContextFreezesRegistryBeforeStartupCompletes() async throws {
    let container = ServiceContainer()
    try await container.register(Token.self) { _ in Token("before freeze") }
    let context = ApplicationContext(container: container, configuration: try ConfigurationLoader.load())

    try await context.start()
    #expect(await container.isFrozen())

    var resolutionError: ServiceContainer.ResolutionError?
    do {
        try await container.register(CycleA.self) { _ in CycleA() }
    } catch let error as ServiceContainer.ResolutionError {
        resolutionError = error
    }
    #expect(resolutionError?.code == "PEARFY_DI_007")
    #expect(try await container.resolve(Token.self).value == "before freeze")
    try await context.stop()
}

@Test func failedStartupRollsBackPreviouslyStartedComponents() async throws {
    let recorder = LifecycleRecorder()
    let context = ApplicationContext(
        configuration: try ConfigurationLoader.load(),
        lifecycle: [
            RecordedLifecycle(name: "database", recorder: recorder),
            RecordedLifecycle(name: "http", recorder: recorder, failsToStart: true)
        ]
    )

    var startupError: ApplicationContext.ContextError?
    do {
        try await context.start()
    } catch let error as ApplicationContext.ContextError {
        startupError = error
    }
    if case .startupFailed(let component, _)? = startupError {
        #expect(component == "http")
    } else {
        Issue.record("Expected a startup failure, got \(String(describing: startupError))")
    }
    let events = await recorder.events
    let failedState = await context.state
    #expect(events == ["start:database", "start:http", "stop:database"])
    #expect(failedState == .failed)
}

@Test func generatedRegistryDiscoversComponentsWithoutManualRegistration() async throws {
    let container = ServiceContainer()
    try await PearfyGeneratedRegistry.registerComponents(in: container)
    let snapshot = try await container.validateGraph()
    let service = try await container.resolve(DiscoveredGreetingService.self)

    #expect(snapshot.registrations.count == 2)
    #expect(service.greet() == "Discovered across test source files")
}

private final class Token: Sendable {
    let value: String
    init(_ value: String) { self.value = value }
}

private protocol Greeter: Sendable {
    var greeting: String { get }
}

private struct FriendlyGreeter: Greeter { let greeting = "Hello" }
private struct FormalGreeter: Greeter { let greeting = "Good day" }
private struct NumberedGreeter: Greeter { let greeting: String }
private struct CycleA: Sendable {}
private struct CycleB: Sendable {}
private struct RequestScopedValue: Sendable { let id: UUID }
private final class RequestScopedReference: Sendable {}
private struct SingletonRequestConsumer: Sendable { let value: RequestScopedValue }

private actor FactoryCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor LifecycleRecorder {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

private struct RecordedLifecycle: ApplicationLifecycle {
    let name: String
    let recorder: LifecycleRecorder
    var failsToStart = false

    func start() async throws {
        await recorder.append("start:\(name)")
        if failsToStart { throw LifecycleTestError.startFailure }
    }

    func stop() async throws {
        await recorder.append("stop:\(name)")
    }
}

private enum LifecycleTestError: Error {
    case startFailure
}

private enum FactoryTestError: Error {
    case failed
}

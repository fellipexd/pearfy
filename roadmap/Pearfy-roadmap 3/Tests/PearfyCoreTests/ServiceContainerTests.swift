import Foundation
import Testing
@testable import PearfyCore

private final class Token: Sendable {
    let id = UUID()
}

@Test func singletonReturnsSameInstance() throws {
    let container = ServiceContainer()
    container.register(Token.self) { _ in Token() }
    let first = try container.resolve(Token.self)
    let second = try container.resolve(Token.self)
    #expect(first === second)
}

@Test func transientReturnsDistinctInstances() throws {
    let container = ServiceContainer()
    container.register(Token.self, scope: .transient) { _ in Token() }
    let first = try container.resolve(Token.self)
    let second = try container.resolve(Token.self)
    #expect(first !== second)
}

@Test func unregisteredServiceThrows() {
    let container = ServiceContainer()
    #expect(throws: ServiceContainer.ResolutionError.self) {
        _ = try container.resolve(Token.self)
    }
}

@Test func circularDependencyThrows() {
    let container = ServiceContainer()
    container.register(Int.self) { resolver in
        try resolver.resolve(Int.self)
    }
    #expect(throws: ServiceContainer.ResolutionError.self) {
        _ = try container.resolve(Int.self)
    }
}

@Test func protocolBindingResolves() throws {
    let container = ServiceContainer()
    container.register((any SendableGreeter).self) { _ in TestGreeter() }
    let greeter = try container.resolve((any SendableGreeter).self)
    #expect(greeter.greet() == "Pearfy")
}

private protocol SendableGreeter: Sendable {
    func greet() -> String
}

private struct TestGreeter: SendableGreeter {
    func greet() -> String { "Pearfy" }
}

import Foundation
import PearfyConfiguration
import PearfyContext
import PearfyDI
import PearfyMacros

struct User: Codable, Sendable {
    let id: UUID
    let name: String
}

protocol UserRepository: Sendable {
    func findById(_ id: UUID) throws -> User
}

@Repository
@Bind((any UserRepository).self)
struct InMemoryUserRepository: UserRepository {
    func findById(_ id: UUID) throws -> User {
        User(id: id, name: "Hello Pearfy")
    }
}

@Service
struct UserService: Sendable {
    @Autowired let repository: any UserRepository

    func findById(_ id: UUID) throws -> User {
        try repository.findById(id)
    }
}

// Keep the @main declaration outside `main.swift` for SwiftPM toolchain compatibility.
@main
struct HelloPearfy {
    static func main() async throws {
        let configuration = try ConfigurationLoader.load(
            defaults: ["application.name": "HelloPearfy"],
            arguments: Array(CommandLine.arguments.dropFirst())
        )
        let container = ServiceContainer()
        try await PearfyGeneratedRegistry.registerComponents(in: container)

        let context = ApplicationContext(container: container, configuration: configuration)
        try await context.start()
        let user = try await container.resolve(UserService.self).findById(UUID())
        try await context.stop()
        let data = try JSONEncoder().encode(user)
        print(String(decoding: data, as: UTF8.self))
    }
}

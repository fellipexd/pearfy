import Foundation
import PearfyCore

struct User: Codable, Sendable {
    let id: UUID
    let name: String
}

protocol UserRepository: Sendable {
    func findById(_ id: UUID) throws -> User
}

struct InMemoryUserRepository: UserRepository {
    func findById(_ id: UUID) throws -> User {
        User(id: id, name: "Hello Pearfy")
    }
}

struct UserService: Sendable {
    let repository: any UserRepository

    func findById(_ id: UUID) throws -> User {
        try repository.findById(id)
    }
}

@main
struct HelloPearfy {
    static func main() throws {
        let container = ServiceContainer()
        container.register((any UserRepository).self) { _ in
            InMemoryUserRepository()
        }
        container.register(UserService.self) { resolver in
            UserService(repository: try resolver.resolve((any UserRepository).self))
        }

        let user = try container.resolve(UserService.self).findById(UUID())
        let data = try JSONEncoder().encode(user)
        print(String(decoding: data, as: UTF8.self))
    }
}

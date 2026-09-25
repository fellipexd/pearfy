import PearfyDI
import PearfyMacros

public protocol GreetingRepository: Sendable {
    func greeting() -> String
}

@Repository
@Bind((any GreetingRepository).self)
struct InMemoryGreetingRepository: GreetingRepository {
    func greeting() -> String { "Hello from a separately built Pearfy feature!" }
}

import PearfyDI
import PearfyMacros

protocol DiscoveredGreetingRepository: Sendable {
    func greeting() -> String
}

@Repository
@Bind((any DiscoveredGreetingRepository).self)
struct InMemoryDiscoveredGreetingRepository: DiscoveredGreetingRepository {
    func greeting() -> String { "Discovered across test source files" }
}

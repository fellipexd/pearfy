import PearfyDI
import PearfyMacros

@Service
public struct GreetingService: Sendable {
    @Autowired public let repository: any GreetingRepository

    public func greet() -> String {
        repository.greeting()
    }
}

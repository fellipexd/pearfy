import PearfyDI
import PearfyMacros

@Service
struct DiscoveredGreetingService: Sendable {
    @Autowired let repository: any DiscoveredGreetingRepository

    func greet() -> String {
        repository.greeting()
    }
}

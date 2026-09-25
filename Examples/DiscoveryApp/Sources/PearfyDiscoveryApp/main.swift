import PearfyConfiguration
import PearfyContext
import PearfyDI
import PearfyGreeterFeature

@main
struct PearfyDiscoveryApp {
    static func main() async throws {
        let container = ServiceContainer()

        // One exported module registry discovers both components in the feature
        // package; the application never registers a repository or service itself.
        try await PearfyGreeterFeature.PearfyGeneratedRegistry.registerComponents(in: container)

        let context = ApplicationContext(
            container: container,
            configuration: try ConfigurationLoader.load()
        )
        try await context.start()
        let greeting = try await container.resolve(GreetingService.self).greet()
        try await context.stop()
        print(greeting)
    }
}

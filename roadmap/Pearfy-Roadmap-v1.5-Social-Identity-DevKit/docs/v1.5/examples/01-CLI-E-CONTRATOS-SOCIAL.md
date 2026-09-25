# Exemplos ilustrativos — CLI e contratos Social

```bash
pearfy modules plan --add social
pearfy add social
pearfy add social-graph
pearfy add social-content
pearfy add social-feed
pearfy add social-moderation
pearfy add identity
pearfy add social-login --providers google,apple
pearfy identity social-storage enable --database postgres --user-table users
pearfy ai init --client opencode
pearfy ai sync
pearfy ai doctor
pearfy guardian verify
```

> Comandos planejados: use `pearfy help`/código atual para saber o que já existe; implemente em fases, não presuma que todos rodam.

```swift
@RouteGroup(name: "mobile", prefix: "/app", sdk: [.ios, .android])
enum MobileAPI {}

@RestController("/posts", group: MobileAPI.self)
final class PostController {
    @Post
    func publish(@RequestBody input: PublishPostInput) async throws -> PostDTO {
        try await posts.publish(input)
    }
}
```

`@RouteGroup` deve respeitar os paths configurados pelo projeto consumidor, sem mudar URLs públicas só para gerar SDK. Tipos específicos da aplicação ficam em adapters versionados; `PostDTO` e content references do núcleo social permanecem genéricos.

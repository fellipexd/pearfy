# Route groups, targets e política de exposição

## Sintaxe Swift-alvo (ilustrativa)

```swift
@RouteGroup(name: "backoffice", prefix: "/bko", sdk: [.typescript])
enum BackofficeAPI {}

@RouteGroup(name: "mobile", prefix: "/app", sdk: [.ios, .android],
            payloadProtection: .bidirectional)
enum MobileAPI {}

@RouteGroup(name: "public", prefix: "/public", sdk: [.ios, .android, .typescript])
enum PublicAPI {}

@RouteGroup(name: "internal", prefix: "/internal", sdk: [])
enum InternalAPI {}

@RestController("/auth", group: BackofficeAPI.self)
final class BackofficeAuthController {
    @Post("/login")
    func login(@RequestBody input: LoginInput) async throws -> AuthResult { /* ... */ }
}
```

Resultado: `POST /bko/auth/login` exportado ao SDK TypeScript do grupo `backoffice`. Separadamente, `MobileAuthController` associado a `MobileAPI.self` produz `POST /app/auth/login` exportado a iOS/Android. Services de domínio podem ser compartilhados, políticas efetivas de autorização podem divergir.

## Especificação da composição

- `name`: ID estável para CLI e manifesto; validar unicidade.
- `prefix`: path normalizado exclusivamente para HTTP/WS; rejeitar `..`, encoding perigoso, duplicidade, dupla barra ambígua, case collision e wildcard conflitante. Definir trailing slash explicitamente.
- `sdk`: conjunto **default/permissão máxima de exportação** do grupo, não permissão de acesso no servidor.
- `version`: versão de contrato; não equivale a uma nova URL automaticamente.
- `authentication`: defaults de geração + metadados de server policy, nunca dispensa a checagem server-side.
- `transport`: exigir HTTPS/WSS/TLS em produção, com verificação de certificado.
- `payloadProtection`: `.transport`, `.request`, `.bidirectional` (se capacidades suportadas).
- `deprecated`: depreciação metadata + horizonte operacional.

## Política de anotação

- Controller/canal/serviço declara `group: NomeDoGrupo.self` explicitamente.
- Sem grupo: privado/não exportável por padrão; opcionalmente erro de compilação em projeto com `groups.strict=true`.
- Overrides endpoint `@SDKOnly([.ios])` **restringem** o conjunto do grupo.
- `@SDKIgnore` exclui operação de bundles/SDKs mas **não** desativa rota no servidor.
- **Não** permitir `@SDKExport([.ios])` ampliar grupo `backoffice` para alvos não autorizados silenciosamente. Se houver exigência real, criar grupo compartilhado/rota apropriada ou alterar política do grupo de forma revisada. Não exportar uma rota de `/bko` como se estivesse em `/app`.
- `SDK` target não representa identidade, autorização ou entitlement do usuário. Qualquer pessoa pode chamar HTTP diretamente; segurança efetiva pertence ao servidor.
- Não expor automaticamente DTO com segredo/campo interno por estar anotado com `Codable`.

## gRPC e WebSocket

- `@SocketChannel("/ws/notifications", group: MobileAPI.self)` -> caminho de handshake `/app/ws/notifications` e eventos daquele canal.
- `@GRPCService(group: MobileAPI.self)` -> metadados de exportação; **não** acrescentar `/app` ao nome fully qualified do serviço Protobuf. Nome real vem do contrato Protobuf.
- Não inferir pertença ao grupo pelo caminho do filesystem, nome de controller ou regex de URL.

## CI e erros

Falhar se: controller faz referência a grupo ausente, target inválido, operação duplicada por method+normalized path, operação exportada sem proteção exigida, policy override reduz requisito mínimo, gerador altera identidade RPC, nomes exportados colidem na linguagem alvo.

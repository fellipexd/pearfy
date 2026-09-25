# Exemplo ilustrativo — declarações Swift do backend

> APIs-alvo; adaptar às macros/regras efetivamente implementadas na branch. Os métodos do exemplo podem ter bodies placeholder **somente nesta documentação**, nunca gerar stubs em cima de código real.

```swift
import Pearfy

@RouteGroup(name: "backoffice", prefix: "/bko", sdk: [.typescript],
            authentication: .required, payloadProtection: .transport)
enum BackofficeAPI {}

@RouteGroup(name: "mobile", prefix: "/app", sdk: [.ios, .android],
            authentication: .required, payloadProtection: .bidirectional)
enum MobileAPI {}

@RouteGroup(name: "public", prefix: "/public", sdk: [.ios, .android, .typescript],
            authentication: .optional, payloadProtection: .transport)
enum PublicAPI {}

@RouteGroup(name: "internal", prefix: "/internal", sdk: [])
enum InternalAPI {}

@RestController("/auth", group: BackofficeAPI.self)
final class BackofficeAuthController {
    @Post("/login")
    @PermitAll // exceção explícita sujeita à policy do servidor
    func login(@RequestBody input: LoginInput) async throws -> AuthResult {
        try await backofficeAuth.login(input)
    }
}

@RestController("/auth", group: MobileAPI.self)
final class MobileAuthController {
    @Post("/login")
    @PermitAll // exceção explícita sujeita à policy do servidor
    func login(@RequestBody input: LoginInput) async throws -> AuthResult {
        try await mobileAuth.login(input)
    }
}

@RestController("/users", group: PublicAPI.self)
final class UserController {
    @Get("/{id}")
    func find(@PathVariable id: UUID) async throws -> UserDTO {
        try await users.findById(id)
    }
}

@RestController("/payments", group: MobileAPI.self)
final class PaymentController {
    @Post("/transfer")
    @Authenticated
    @SealedPayload(.bidirectional)
    func transfer(@RequestBody input: TransferInput) async throws -> TransferResult {
        try await payments.transfer(input)
    }
}

@SocketChannel("/ws/notifications", group: MobileAPI.self)
final class NotificationSocket {
    @SocketEvent("notification.created")
    func created() -> NotificationDTO { /* evento tipado ilustrativo */ }
}

@GRPCService(group: MobileAPI.self)
final class NotificationGRPC {
    @GRPCMethod
    func subscribe(_ input: SubscribeRequest) async throws -> NotificationStream {
        /* stream tipado ilustrativo */
    }
}
```

## Matriz de exportação

| Operação | Rota/serviço | Swift iOS | Kotlin Android | TS |
|---|---|---:|---:|---:|
| backoffice.login | POST `/bko/auth/login` | não | não | sim |
| mobile.login | POST `/app/auth/login` | sim | sim | não |
| users.find | GET `/public/users/{id}` | sim | sim | sim |
| payments.transfer | POST `/app/payments/transfer` | sim | sim | não |
| notifications.created | WS `/app/ws/notifications` | sim | sim | não |
| NotificationGRPC.subscribe | gRPC service/method original | sim | sim | não |

## Nota sobre login

Rotas de login precisam de auth `.permitAll`/equivalente **explicitamente autorizado** no servidor, ainda que o grupo exija auth por padrão para as demais operações. A configuração acima é uma ilustração de estrutura, não uma política executável nem uma autorização para permitir login anônimo em todas as rotas.

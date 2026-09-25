# API pública desejada — especificação, NÃO implementação

O código abaixo serve como contrato a validar por POC de macros. **O pacote executável neste ZIP não disponibiliza essas annotations nem HTTP/DB.** Ajustar sintaxe onde restrições do compilador impedirem reprodução literal.

## Bootstrap e HTTP

```swift
import Foundation
import Pearfy

@main
@PearfyApplication
struct Application {
    static func main() async throws {
        try await Pearfy.run()
    }
}

@RestController("/api/v1/users")
final class UserController {
    @Autowired let service: UserService

    @Get("/{id}")
    func find(@PathVariable id: UUID) async throws -> UserDTO {
        try await service.findById(id)
    }

    @Post
    @ResponseStatus(.created)
    func create(@Valid @RequestBody input: CreateUserDTO) async throws -> UserDTO {
        try await service.create(input)
    }
}
```

## DI de protocolo e configuração

```swift
protocol PaymentGateway: Sendable {
    func charge(amount: Decimal) async throws
}

@Service
@Bind(PaymentGateway.self)
@Qualifier("primary-provider")
final class DefaultGateway: PaymentGateway {
    func charge(amount: Decimal) async throws { /* adapter */ }
}

@Service
final class PaymentService {
    @Autowired @Qualifier("primary-provider")
    let gateway: any PaymentGateway
}

@Configuration
struct DatabaseConfiguration {
    @Bean
    func database(@Value("database.url") url: String) async throws -> Database {
        try await Database.connect(url: url)
    }
}
```

## Transação, autorização e cache

```swift
@Service
final class TransferService {
    @Autowired let accounts: AccountRepository

    @Transactional
    func transfer(from: UUID, to: UUID, amount: Decimal) async throws {
        try await accounts.debit(from, amount: amount)
        try await accounts.credit(to, amount: amount)
    }
}

@RestController("/admin")
@Authenticated
final class AdminController {
    @Get("/users") @RolesAllowed("ADMIN")
    func list() async throws -> [UserDTO] { /* ... */ }
}

@Service
final class GameService {
    @Cacheable(key: "game:{id}", ttl: .minutes(10))
    func find(id: UUID) async throws -> Game { /* ... */ }
}
```

## Jobs e mensageria

```swift
@Component
final class CleanupJob {
    @Scheduled(cron: "0 0 3 * * *")
    func cleanup() async throws { /* ... */ }
}

@Service
final class PaymentConsumer {
    @RabbitListener("payment.completed")
    func handle(event: PaymentCompleted) async throws { /* ... */ }
}
```

## CLI-alvo

```bash
pearfy new my-api
cd my-api
pearfy add data-postgres
pearfy dev
pearfy routes
pearfy doctor
```

`dev` deverá fazer **rebuild + restart**, sem anunciar hot reload em runtime. `@Transactional`, `@Cacheable` e method security exigem wrappers/interceptação gerados e validação de chamadas internas, não apenas metadados.

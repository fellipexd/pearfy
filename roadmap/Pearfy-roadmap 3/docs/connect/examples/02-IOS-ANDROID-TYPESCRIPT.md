# Exemplos de consumo — SDKs gerados (APIs-alvo)

Os pacotes e nomes exemplificam a experiência desejada; a geração deve conservar nomes idiomáticos, schemas compartilhados e a semântica do endpoint. O host não contém `/app`, `/bko` nem `/public`: o client monta a rota a partir do contrato.

## Swift / iOS — rota pública

```swift
import PearfyPublicClient

let api = PublicClient(baseURL: URL(string: "https://api.example.com")!)
let user: UserDTO = try await api.users.find(id: userId)
print(user.name)
```

## Kotlin / Android — mesma rota

```kotlin
import com.pearfy.publicclient.PublicClient

val api = PublicClient(baseUrl = "https://api.example.com")
val user: UserDTO = api.users.find(id = userId) // dentro de coroutine
println(user.name)
```

## TypeScript — mesma rota

```typescript
import { PublicClient } from "@pearfy/public-client";
const api = new PublicClient({ baseURL: "https://api.example.com" });
const user = await api.users.find({ id: userId });
console.log(user.name);
```

Todos chamam `GET /public/users/{id}`. `UserDTO` vem do contrato, sem model manual duplicado.

## Login Backoffice — **somente TypeScript**

```typescript
import { BackofficeClient } from "@pearfy/backoffice";
const bko = new BackofficeClient({ baseURL: "https://api.example.com" });
const session = await bko.auth.login({ email, password });
// POST /bko/auth/login
```

## Pagamento com payload sealed — **iOS e Android**

```swift
let mobile = MobileClient(baseURL: URL(string: "https://api.example.com")!)
let result: TransferResult = try await mobile.payments.transfer(
    TransferInput(
        requestId: existingRequestId,
        sourceAccount: source,
        destinationAccount: destination,
        amount: Money(value: Decimal(string: "150.00")!, currency: .brl)
    )
)
```

```kotlin
val mobile = MobileClient(baseUrl = "https://api.example.com")
val result: TransferResult = mobile.payments.transfer(
    TransferInput(
        requestId = existingRequestId,
        sourceAccount = source,
        destinationAccount = destination,
        amount = Money(value = BigDecimal("150.00"), currency = Currency.BRL)
    )
)
```

O SDK cuida de TLS + proteção opcional de mensagem + auth + codecs + erros. O pagamento é executado no backend pelo PaymentEngine com atomicidade/idempotência em banco compartilhado, **não** no client.

## WebSocket tipado

```swift
for try await event in mobile.notifications.events {
    switch event {
    case .created(let notification): print(notification.title)
    }
}
```

```kotlin
mobile.notifications.events.collect { event ->
    when (event) {
        is NotificationEvent.Created -> println(event.notification.title)
    }
}
```

```typescript
// Disponível apenas se grupo do canal incluir .typescript.
const stop = api.notifications.on("notification.created", event => {
  console.log(event.title);
});
```

## gRPC unary / streams

```swift
let status = try await mobile.presence.getStatus(userId: userId)
```

```kotlin
val status = mobile.presence.getStatus(userId = userId)
```

```typescript
// Se o target browser/Node suportar o transporte selecionado:
const status = await api.presence.getStatus({ userId });
```

**Não** inserir essas APIs TypeScript num pacote de grupo que só exporta iOS/Android. Os trechos TS WebSocket/gRPC acima representam um grupo que explicitamente permite TypeScript ou demonstram a assinatura idiomática planejada; não alteram a política de `MobileAPI`.

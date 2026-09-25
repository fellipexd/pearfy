# SDKs gerados: Swift/iOS, Kotlin/Android e TypeScript

## Contrato de experiência

A operação `GET /public/users/{id}` torna-se `users.find`, com entrada e resposta fortemente tipadas, docstrings, suporte a erros, auth, deadlines, cancellation e codecs apropriados. O gerador não deve expor `Map<String, Any>`, `[String: Any]` ou `any` como substituto silencioso de schema que pode ser tipado. Campos unknown em DTOs devem seguir política explícita de forward compatibility.

| Alvo | Pacote primário | Idioma/API | Assíncrono |
|---|---|---|---|
| iOS | Swift Package; XCFramework opcional e compilado por plataforma/arch | Swift + Codable | `async throws`, `AsyncSequence` para streams |
| Android | Kotlin Gradle/AAR ou publicação Maven | Kotlin + serialização tipada | `suspend`, `Flow` para streams |
| TypeScript | npm ESM/CJS conforme targets declarados e TypeScript `.d.ts` | browser e Node com adapters distintos | `Promise`, `AsyncIterable`/event subscription |

## Interface comum, idiomática

- `api.users.find(...)`, `api.auth.login(...)`, `api.payments.transfer(...)`.
- Erro tipado com classe/enum e payload de negócio **sem confundir** HTTP 4xx/5xx, código de transporte, timeout, cancelamento, falha criptográfica e resultado ambíguo.
- Options de request tipadas: timeout, cancellation, trace id, locale, idempotency key fornecida pelo chamador quando pertinente.
- Injetar client HTTP/clock/secure store nos testes sem tornar API pública complicada.
- Client thread-safe/concurrency-safe conforme linguagem; bounded queues/reconnect; não reter secrets em logs.
- Uma chamada não deve inventar uma nova idempotency key em cada retry: preservar intenção do chamador.
- Não repetir POST não idempotente automaticamente sem regra e confirmação de suporte no servidor; status de commit unknown deve ser consultável com chave persistente.

## Auth

- Token provider próprio por plataforma, scoped per client instance; renovação single-flight com limites, revogação e logout.
- iOS: Keychain para credenciais persistidas quando apropriado; Android: Keystore-backed solution sem prometer que todo armazenamento direto é cifrado; browser: avaliar cookies HttpOnly/SameSite, CSRF, XSS, em vez de afirmar que localStorage é seguro para segredos.
- OAuth2/OIDC native: authorization code + PKCE quando aplicável; no client secret estático dentro de app público.
- WS browser: não assumir suporte arbitrário a headers no construtor WebSocket; handshake via cookie/subprotocol/ticket efêmero apropriado e revisado.
- gRPC auth em metadata, compatível com target e transport.

## Criptografia

TLS é obrigatório em produção. Com policy extra, o SDK usa implementação auditável/interoperável do protocolo (ver `05-SECURE-PAYLOAD-E-CHAVES.md`) e entrega DTO descriptografado ao app. Não expor APIs que convidam a envio de payload em claro em rota protegida.

## Compatibilidade e publicação

- Pacote por `group + target`, opcional agregador por target/namespace para vários grupos; não criar colisões de `users.find`.
- Namespace público estável (ex.: `PearfyMobileClient`, `@pearfy/backoffice`).
- Versionar pacote separadamente de versão de backend, registrando `contractHash` e supported server contract range. SDK pode validar versão quando servidor fornecer capability endpoint.
- Não presumir rollout simultâneo de app mobile e servidor; guardar golden contracts por versões realmente publicadas.
- Gerar README, changelog, licenças de dependências, exemplo mínimo, SBOM quando requerido pelo pipeline.

## Não gerar automaticamente

- UI visual, telas SwiftUI/Compose ou código baixado/executado remotamente no iOS.
- Credenciais privadas, database access, chamadas não autorizadas, endpoints internos não exportados.
- Fallback silencioso de HTTP seguro para HTTP inseguro, nem payload protegido para texto claro.

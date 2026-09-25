# Pearfy — implementação e testes

**Atualizado em:** 25 de setembro de 2026

**Escopo:** funcionalidades presentes neste checkout e verificações executadas localmente. Inclui slices dos roadmaps 2/3 e v1.5; não declara esses roadmaps concluídos.

## O que está implementado

- **DI e ciclo de vida:** registry e validação antecipada de dependências, singletons e factories assíncronas concorrentes, bindings por tipo/qualifier, escopos de request e inicialização/encerramento ordenados.
- **Macros, discovery e schema:** macros para componentes/controllers, `@Entity/@ID/@Column`, Route Groups, `@ContractModel/@ContractField` para schemas Connect de DTOs Codable opt-in, registries AOT por target, UUIDv7 e scaffold `HelloPearfy`.
- **Web, HTTP e Connect:** router com grupos/prefixos, IR determinístico com operation/auth metadata e refs request/response, schemas registrados resolvidos transitivamente, OpenAPI 3.1 filtrado por grupo, limites, admission/deadline; listener HTTP/1.1 SwiftNIO e shutdown gracioso. SDK generation continua desabilitada enquanto a cobertura de schemas e o diff compatível não estiverem completos.
- **Validação e segurança:** validação declarativa e por macros, API key, JWT HMAC, autenticação Bearer e autorização por roles.
- **Dados e adapters:** SQL parametrizado, adapter PostgreSQL transacional, SchemaIR/fingerprint, plano PostgreSQL inicial e migrations com checksum SHA-256, detecção de drift e lock transacional; `PearfyTransactions` fornece unit-of-work genérica REQUIRED, rollback-only e classificação de commit unknown.
- **Cache e messaging:** cache local/Redis e broker local/Redis com ack, retry, DLQ e recuperação.
- **Social v1.5 (slice inicial):** `PearfySocial` define atores, handles validados, visibilidade e contrato do grafo; `PearfySocialPostgres` persiste atores, follows e blocks, aplicando ownership e regras básicas de leitura.
- **Concorrência e integrações:** scheduler local fixed-delay; cliente HTTP outbound com limites de concorrência/fila, cancelamento, retries idempotentes e circuit breaker; cliente de chat compatível com API OpenAI.
- **Operação e extensibilidade:** health/readiness, métricas Prometheus, CLI `pearfy` com Module Manager, scaffold, `pearfy mcp` read-only para inspeção do projeto/módulos, e `pearfy-bench` para profiling/benchmarks.

Roadmaps 2/3/v1.5 ainda têm entregas ausentes; as matrizes detalhadas estão em `roadmap/ESTADO-IMPLEMENTACAO-ROADMAPS-2-3.md` e `roadmap/ESTADO-IMPLEMENTACAO-V1.5.md`. O escopo é tornar as capacidades Pearfy genéricas e opt-in.

## Testes e verificações executados

Executados no checkout em macOS arm64, com Apple Swift 6.4:

| Comando | Resultado |
|---|---|
| `bash scripts/test-unit.sh` | 101 testes passaram em Debug; sem os hosts de serviços configurados, os testes de integração externa retornam sem conectar. Inclui o teste MCP read-only. |
| `bash scripts/test-integrations.sh` | 101 testes passaram em Debug com PostgreSQL e Redis locais reais, incluindo schemas Connect descobertos via `@ContractModel`, MCP read-only, Social, Transaction Manager e migration artifacts/plan/locking/drift. |
| `bash scripts/test-integrations.sh -c release` | Os mesmos 101 testes passaram em Release com integrações reais, incluindo schemas Connect descobertos via `@ContractModel`, MCP read-only, Social, Transaction Manager e migration artifacts/plan/locking/drift. |
| `bash scripts/verify-aot-snapshot.sh` | Registry AOT gerado corresponde ao snapshot versionado. |
| Build dos exemplos `GreeterFeature` e `DiscoveryApp` | Ambos compilaram após as macros de entidade/discovery. |

O Module Manager também foi exercitado em um scaffold temporário: `add postgres`, `doctor`, build, `remove postgres`, novo `doctor` e rebuild passaram.

## Limites conhecidos

- O `PostgresSchemaCompiler` ainda não exporta seus planos como artifacts versionados; essa capacidade é coberta separadamente por `SQLMigrationCatalog`/`SQLMigrationRunner`, com checksum, drift e locking, mas sem rollback plan ou CLI.
- PearfyConnect gera snapshot de rotas e refs de schema; DTOs precisam de opt-in com `@ContractModel`, e a cobertura de Codable ainda é limitada. Não há pacote `.pearfy`, diff compatível nem SDKs gerados.
- O servidor MCP só oferece inspeção e planos read-only; não faz code search, aplica mudanças, executa testes ou oferece políticas de autorização por workspace.
- O Module Manager só instala produtos existentes neste checkout; ainda não há registry assinado/SemVer nem extensões de domínio.
- PaymentEngine, ORM, Guardian, Webhooks/Outbox/jobs duráveis, logs sanitizados/OTLP, Backoffice/Approvals/CRM, Chatbot, WhatsApp, tools avançadas do MCP e gRPC continuam pendentes.
- A integração multi-processo/multi-réplica, failover e CI remoto ainda não foram validados.

# Backlog inicial priorizado

Marcação: `[ ]` pendente, `[x]` protótipo existente. IDs são estáveis para issues futuras. Não interpretar o protótipo como fase concluída.

## M0 — Base de DI e app context

- [x] `PDI-000` Protótipo de DI por construtor singleton/transient com 5 testes.
- [ ] `PDI-001` Extrair contratos do container e remover pressupostos de factories apenas síncronas. Aceite: API limpa de runtime e tests multi-contexto.
- [ ] `PDI-002` Registrar tipos/protocolos, qualifier e primary. Aceite: ambiguidade diagnóstica e override isolado.
- [ ] `PDI-003` Resolver grafo concorrente e factories async. Aceite: singleton criado uma vez sob 100 resolves simultâneos; sem lock através de await.
- [ ] `PDI-004` Ciclos diretos/indiretos com trilha de resolução. Aceite: erro `PEARFY_DI_003` inclui caminho de tipos.
- [ ] `PDI-005` Lifecycle start/stop e failure rollback. Aceite: shutdown reverso e sem recursos órfãos.
- [ ] `PDI-006` Profiles/config tipados e overrides. Aceite: validação env/arquivo CLI + redaction.
- [ ] `PDI-007` Test context, mocks e snapshots de grafo. Aceite: parallel tests sem compartilhamento de singleton.

## M1 — POC macros e discovery

- [ ] `PMAC-001` Pacotes macro SwiftSyntax e testes de expansão; `@Service` e `@Repository` em arquivos distintos.
- [ ] `PMAC-002` `@Autowired` gera init/factory segura e detecta uso proibido. Aceite: sem `T!` nem service locator invisível.
- [ ] `PMAC-003` `@Bind`, `@Qualifier`, `@Primary` com diagnóstico de binding ausente/ambíguo.
- [ ] `PDIS-001` Build plugin gera manifest/registry por target; teste com aplicação e dois módulos SPM.
- [ ] `PDIS-002` Invalidação incremental do manifesto ao alterar componentes.
- [ ] `PCTX-001` Context bootstrap pelo registry, validação antes do HTTP.

## M2 — Web e CLI

- [ ] `PWEB-001` Modelos Request/Response/HTTPError e router in-memory com testes.
- [ ] `PWEB-002` Adaptador NIO HTTP listener e graceful shutdown.
- [ ] `PWEB-003` Macros `@RestController`, `@Get`, `@Post`, binding e resposta JSON.
- [ ] `PWEB-004` Middleware, body limits, request ID, erros padronizados.
- [ ] `PWEB-005` OpenAPI, SSE/WebSocket após estabilidade HTTP básica.
- [ ] `PCLI-001` `pearfy new`, `dev`, `run`, `build`, `test`, `doctor`.
- [ ] `PCLI-002` Aplicação zero registro manual `GET /hello` e `POST /users` em CI.

## M3 — Dados e segurança

- [ ] `PDAT-001` Postgres driver/pool/migration/queries parametrizadas.
- [ ] `PDAT-002` Transaction context async, propagation e rollback.
- [ ] `PDAT-003` Repository macro e paginação.
- [ ] `PVAL-001` Validation do request e DTO.
- [ ] `PSEC-001` Middleware auth + deny-by-default.
- [ ] `PSEC-002` JWT seguro, issuer/audience/JWKS/key rotation.
- [ ] `PSEC-003` Method security, sessão opcional, CSRF onde couber.
- [ ] `POPS-001` Actuator, OTel, logs/metrics e shutdown.

## M4 — Extensões

- [ ] `PCAC-001` Cache memory/Redis e invalidação.
- [ ] `PMSG-001` RabbitMQ/Kafka adapter, retries, idempotência, DLQ.
- [ ] `PJOB-001` Scheduler e execução distribuída.
- [ ] `PCLD-001` HTTP client declarativo, circuit breaker e retry seguro.
- [ ] `PAI-001` Contratos AI e adapters opcionais (após núcleo estável).

## Definição universal de pronto

Implementação + documentação + testes + exemplos + diagnóstico de erro + compatibilidade macOS/Linux + sem dependência opcional vazando para Core.

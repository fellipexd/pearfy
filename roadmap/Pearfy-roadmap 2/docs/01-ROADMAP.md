# Roadmap Pearfy — 0.1 a 1.0

## Norte do produto

Em até dois comandos de terminal, criar e executar uma API Swift. A infraestrutura fica encapsulada em starters; o núcleo fornece contexto de aplicação, injeção de dependências, lifecycle, configurações e diagnóstico. O conjunto de capacidades busca cobrir as partes mais importantes do Spring Boot e dos projetos Spring correlatos, sem reproduzir código, arquitetura interna ou nomes de classes deles.

**Acordos de escopo:** Swift 6.x com strict concurrency; macOS/Linux inicialmente; SPM; `async/await`; dependências opt-in; primeira persistência PostgreSQL; backends adicionais depois de estabilidade. Versões abaixo são **marcos pretendidos, não datas nem promessas de lançamento**. `PearfyTesting` existe desde 0.1, embora evolua nas demais fases.

## Fase 0 — 0.1: Núcleo de aplicações [P0]

- `PearfyCore`, `PearfyContext`, `PearfyDI`, `PearfyConfiguration`, `PearfyLifecycle`, `PearfyTesting`.
- Registro por protocolos/tipos, factories síncronas e assíncronas, singleton e transient; bootstrap e shutdown ordenados.
- Configuração tipada, precedência entre arquivo/env/CLI, profiles, falha explicativa para config inválida.
- Graph validation: dependência ausente, duplicidade, ciclo e ambiguidade por qualifier.
- Modelo de erro estável; suporte a cancellation; preservação de `Sendable`.

**Gate:** inicialização de aplicação sem HTTP; teste Linux/macOS; factories async; ciclos com caminho completo; shutdown reverso; isolamento de contextos entre testes. O protótipo no ZIP é apenas uma fração dessa fase.

## Fase 1 — 0.2: Macros, discovery, web e CLI [P0]

- `PearfyMacros`, `PearfyMacrosImpl`, `PearfyDiscovery`, plugin de build e registry gerado.
- Macros alvo `@PearfyApplication`, `@Component`, `@Service`, `@Repository`, `@Configuration`, `@Bean`, `@Autowired`, `@Inject`, `@Qualifier`, `@Primary`, `@Scope`, `@Profile`.
- `PearfyWeb` / `PearfyNIO`: GET/POST/PUT/PATCH/DELETE, path/query/header/body, erros e respostas tipadas, middleware, JSON, body limits, graceful shutdown.
- `PearfyCLI`: `new`, `dev` (rebuild + restart), `run`, `build`, `test`, `doctor`, `routes`, `beans`.
- OpenAPI inicial, request ID, logging, health mínimo, testes de controller.

**Gate:** app de exemplo com controller → service → repository, sem registro manual, `GET /hello`, `POST /users`, validação de request e shutdown; demo Linux/macOS; invalid DI aborta antes de abrir socket.

## Fase 2 — 0.3: Data e transações [P0]

- `PearfyData`, `PearfyPostgres`, `PearfySQLite` (testes/desenvolvimento), migrações, pool e observabilidade SQL.
- Mapeamento tipado, queries parametrizadas, paginação, sort, auditoria, repositórios; ORM avançado opcional e posterior.
- `@Transactional` com propagação, isolamento, rollback, commit e contexto async sem vazamento de conexão.
- Testes de concorrência transacional, rollback e injeção SQL; documentação de limites do modelo de interceptação.

**Gate:** CRUD persistido, rollback demonstrado, migrações idempotentes; PostgreSQL real em CI.

## Fase 3 — 0.4: Validation e configuração [P0]

- `PearfyValidation`: `@Valid`, not blank, size, min/max, formato, DTOs e erros padronizados.
- Config profiles, secrets, configuração por módulo, diagnostics de startup, reload apenas de opções explicitamente suportadas.
- OpenAPI atualizado com constraints e respostas de erro.

**Gate:** invalid payload retorna status, lista de campos e código previsíveis; env overrides testados e segredos redigidos em logs.

## Fase 4 — 0.5: Security [P0 para produção]

- `PearfySecurity`: autenticação por JWT e API key; OIDC/OAuth2 client/resource server em escopo documentado; autenticação por sessão opcional.
- `@Authenticated`, `@PermitAll`, `@RolesAllowed`, políticas e method security gerada/interceptada.
- Política deny-by-default, validação `issuer`/`audience`/algoritmo/chaves, chave rotativa, CSRF em cenário cookie, headers de segurança e CORS.
- Testes adversariais para bypass, token inválido, sessão expirada e autorização entre tenants.

**Gate:** revisão independente antes de prometer uso em aplicações sensíveis; cobertura de caminhos negados, sem fallback inseguro.

## Fase 5 — 0.6: Actuator, operação e tracing [P0 para produção]

- `PearfyActuator` e wrappers de Swift Log, Swift Metrics, tracing e OpenTelemetry.
- Liveness/readiness/health, métricas de latência e erros, traces e correlação, diagnostics protegidos, config sanitizada.
- Suporte Docker/Kubernetes, shutdown cooperativo, gestão de sinais, readiness durante startup e draining.

**Gate:** dashboards funcionais; soak/load tests; observability sem expor dados sensíveis.

## Fase 6 — 0.7: Cache e messaging [P1]

- `PearfyCache`, `PearfyRedis`; `@Cacheable`, `@CacheEvict`, TTL e invalidação.
- `PearfyMessaging`, adapters RabbitMQ e Kafka, Redis Streams opcional; retry/backoff, DLQ, idempotência e backpressure.
- Sem promessas genéricas de exactly-once; semânticas por driver documentadas.

**Gate:** falhas simuladas, retry, duplicate messages, indisponibilidade Redis/broker e recovery testados.

## Fase 7 — 0.8: Jobs e batch [P1]

- `PearfyJobs`, `PearfyBatch`; `@Scheduled`, cron, fixed delay, checkpoint, cancellation, concorrência e execução distribuída.
- Historizar execução, política de timeout, retries, locks e documentação de timezones.

**Gate:** cluster não executa duas vezes um job anunciado como exclusivo, na falha simulada especificada.

## Fase 8 — 0.9: Cloud e contratos externos [P2]

- `PearfyCloud`: HTTP client declarativo, retries seguros, circuit breaker, bulkhead, gateway/adapters, config e discovery opcionais.
- gRPC/GraphQL opcionais, Kubernetes integration; soluções externas preferidas a reinventar orquestração.

**Gate:** testes de resiliência e documentação por adapter.

## Fase 9 — ≥1.x: AI e extensões [P2]

- `PearfyAI`: ChatClient, streaming, embeddings, tool calling, structured output, RAG e drivers opt-in.
- Drivers MySQL/MongoDB, sessões HTTP avançadas, packages especializados depois do núcleo estabilizado.
- Recursos experimentais não devem bloquear lançamento de 1.0 do núcleo estável.

## Release 1.0 — gates transversais

- API pública versionada e documentada; migrações de versões; políticas de breaking changes.
- Builds e testes Swift macOS/Linux; concurrency sanitizer quando disponível; testes de rede/DB reais.
- Auditorias de dependências e segurança, threat model, benchmarks reprodutíveis e perfis de memória.
- Exemplos de API mínima e serviço de produção; release notes e changelog; suporte/triagem definidos.
- Não marcar um módulo como estável se não passou seu gate. É aceitável publicar 1.0 do núcleo com starters explicitamente beta.

## Dependências críticas

`Core → DI/Context/Config/Lifecycle → Macros/Discovery → Web/CLI → Data/Validation → Security → Actuator → Cache/Messaging → Jobs → Cloud → AI`.

`Testing` e documentação atravessam **todas** as etapas. Security não pode ser reduzido a “JWT funciona”: política de autorização e auditoria fazem parte do gate.

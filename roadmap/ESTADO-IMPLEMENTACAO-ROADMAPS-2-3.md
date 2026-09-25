# Estado de implementação — roadmaps 2 e 3

Atualizado em 2026-09-25 contra o código e testes do checkout ativo. As pastas `Pearfy-roadmap 2/` e `Pearfy-roadmap 3/` são preservadas como fontes de planejamento e protótipo histórico, não como prova de entrega.

## Roadmap 2 — dados, transações e capacidades de aplicação

| Marco | Estado | Evidência e limite |
|---|---|---|
| G0 — inventário | Feito | Este documento registra pronto/parcial/ausente sem usar exemplos de roadmap como evidência. |
| G1 — contratos e DI | Majoritariamente implementado | DI async, scopes, macros e discovery por target têm implementação e testes. |
| G2 — schema compiler | Parcial | `@Entity/@ID/@Column` gera descritores e o plugin agrega schemas do target; `SchemaIR` valida, normaliza e calcula SHA-256; UUIDv7 é metadata padrão de `@ID UUID`. Faltam discovery global entre packages, relações e geração automática de IDs no construtor. |
| G3 — migrations | Parcial | `PostgresSchemaCompiler` gera CREATE/add-nullable e mudanças explícitas revisáveis, bloqueia coluna obrigatória sem default/backfill e exige aprovação para drops/rename; DDL inicial/add-column passou contra PostgreSQL real. `SQLMigrationCatalog` carrega JSON versionado com parâmetros; `SQLMigrationRunner` registra SHA-256 de up/down/parameters, detecta drift para IDs declarados, adota journal legado, serializa por advisory transaction lock e expõe `plan` sem DDL de domínio. Dois clientes simultâneos, rollback, falha e drift passaram em PostgreSQL real. Faltam detecção de versões removidas/gaps, plano de rollback e CLI plan/deploy. |
| G4 — transações | Parcial | `PearfyTransactions` define `PearfyTransactionalStore` e `PearfyTransactionManager` independentes de domínio; REQUIRED reaproveita a mesma unit of work, inner failure marca rollback-only e commit unknown é tipado. `PearfyPostgresDatabase` adapta seu `withTransaction` físico e classifica erros de COMMIT desconhecido. Unit tests cobrem propagation/cancelamento/unknown; PostgreSQL real cobre commit e rollback. Faltam `.requiresNew`/`.nested`, segurança de uso concorrente do unit, fault injection de commit ambíguo e reconciliação antes de retry. |
| G5 — ORM/query builder | Parcial | Builders SQL tipados/parametrizados existem; não há ORM model-first, relações, projeções, cursor ou query builder de key paths. |
| G6 — locking/concurrency | Parcial | Admission control, pool bounded, cancelamento, queries concorrentes e lock durável de migrations entre clientes PostgreSQL testados; faltam locks duráveis de dados, conditional writes, retry classificado por driver e testes de concorrência do store. |
| G7 — multi-instância | Parcial | Migrations foram concorridas em dois clientes PostgreSQL independentes; ainda não há teste de processos separados para invariantes/idempotência de dados nem validação de failover. |
| G8 — PaymentEngine | Ausente | Sem Money/transferências/reservas/ledger/idempotência/outbox financeiros. |
| G9 — Guardian | Ausente | Workflow de build/teste e verificações pontuais existem; não há enforcement fail-closed das políticas de SQL, migration, pagamentos ou Connect. |
| G10 — gRPC/MCP | Ausente | Não há transporte gRPC nem servidor MCP. |
| G11 — release | Parcial | 100 testes locais passam em Debug/Release com PostgreSQL/Redis, incluindo Connect schemas, Social/PostgreSQL, transaction manager e migration artifacts/plan/locking/drift; workflow macOS/Linux está configurado, mas sem execução remota e sem revisão/certificação completa de release. |

## Roadmap 3 — Connect v1.3 e extensões v1.4

### Pearfy Connect

- **PCON-000 — inventário:** feito.
- **PCON-001 — Route Groups:** fatia implementada: `@RouteGroup` descreve ID/prefix/SDK targets; `@RestController(group:)` compõe o prefixo, registra o grupo e mantém autorização independente; OpenAPI e descritores de rota podem ser filtrados por grupo.
- **PCON-002/003 — IR/OpenAPI:** parcial. `PearfyConnectCompiler` gera snapshot JSON determinístico com revision/hash, grupos, operation IDs/path parameters, auth policies e referências request/response; builtins e schemas registrados são resolvidos transitivamente e schemas ausentes bloqueiam compile. `@ContractModel` e `@ContractField` geram descritores para DTOs Codable explicitamente marcados, e o plugin agrega esses schemas por target, incluindo campos escalares/opcionais e helpers de arrays. OpenAPI exporta grupos e type refs, mas SDK generation permanece desligada; faltam cobertura mais ampla de DTOs/Codable, `.pearfy` e diff compatível.
- **PCON-004–008 — pacote, SDKs e exports:** ausentes; sem SDK iOS/Android/TypeScript gerado, Postman ou cURL individual.
- **PCON-009–018 — Guardian, compatibilidade, WS/gRPC e payload sealed:** ausentes.

### Extensões v1.4

| Marco | Estado |
|---|---|
| E0 inventory | Feito; esta matriz é a fonte factual inicial. |
| E1 Module Manager | Parcial/primeira entrega: catálogo JSON dos produtos existentes, dependency graph e `modules list/info/doctor/plan`, `add/remove [--dry-run]`; altera apenas markers de scaffold e `.pearfy/modules.json`; add/remove repetidos são idempotentes. Faltam manifests SemVer assinados, update/rollback de versões e registry externo; produtos futuros são rejeitados. |
| E2–E3 Logs/exportadores | Ausentes como módulo; há `swift-log` em Postgres, mas não PearfyLogs com sanitização/OTLP. |
| E4 Webhooks/Outbox/Jobs duráveis | Parcial: scheduler local fixed-delay existe; inbox/outbox, leases/fencing e jobs duráveis/multi-instância não. |
| E5 PearfyAI central | Parcial: cliente OpenAI-compatible não-streaming existe; sem profiles/providers centrais, política de dados/custo, streaming ou seleção de fallback fail-closed. |
| E6 Messaging/canais | Parcial: brokers in-memory/Redis têm ack/retry/DLQ; sem Telegram/WhatsApp, webhook inbox ou leases de worker multi-host. |
| E7–E8 Chatbot/WhatsApp | Ausentes. |
| E9 Observability | Parcial: health/readiness, métricas Prometheus, HTTP/cache/outbound existem; sem tracing/exporters integrados e métricas de DB/jobs. |
| E10 MetricAI | Ausente. |
| E11–E15 Backoffice, Approvals, Connect BKO, CRM, Insights | Ausentes. |
| E16 Notifications/Storage/Identity/Realtime/Integrations | Ausentes como módulos; HTTP outbound genérico existe parcialmente. |
| E17 Blueprints | Ausente. |

## Validação da fatia atual

- `bash scripts/test-integrations.sh`: 100 testes passaram em Debug com PostgreSQL e Redis locais; inclui groups/Connect schema snapshot, Entity/Schema registry, UUIDv7, schema plans, migration artifacts/plans/checksums/locks, Transaction Manager, Module Manager, Social graph, HTTP, DI e adapters.
- `bash scripts/test-integrations.sh -c release`: os mesmos 100 passaram em Release.
- `bash scripts/verify-aot-snapshot.sh`: passou; `Examples/GreeterFeature` e `Examples/DiscoveryApp` compilaram após as alterações de macros.
- E2E local do Module Manager: scaffold, `add postgres`, `doctor` e build; `remove postgres`, `doctor` e novo build passaram.

## Próxima sequência

1. Fechar G3 com checagem de gaps/removals, rollback plans e comandos seguros de plan/deploy; catálogo versionado e API de plan já existem.
2. Completar o transaction manager com serialização de acesso ao unit, fault/reconciliation tests de commit unknown e propagation adicional antes de Payments/Approvals.
3. Expandir PCON-002 além dos DTOs marcados com `@ContractModel`, gerar `.pearfy` determinístico e validar diff/paridade antes dos SDKs.
4. Evoluir Module Manager para manifests versionados/assinados e update SemVer, mantendo rejeição de produtos ainda inexistentes.
5. Continuar Connect SDKs e extensões por dependências, com credenciais/ambientes reais apenas quando disponíveis.
6. Acompanhar a evolução das capacidades Social/Identity/DevKit no documento `ESTADO-IMPLEMENTACAO-V1.5.md`, mantendo APIs genéricas, opt-in e sustentadas por código/testes.

Os roadmaps 2 e 3 **não estão completos**; a tabela marca apenas o estado sustentado pelo código e testes presentes.

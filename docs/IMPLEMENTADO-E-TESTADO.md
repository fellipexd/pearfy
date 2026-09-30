# Pearfy — implementação e testes

**Atualizado em:** 26 de setembro de 2026

**Escopo:** funcionalidades presentes neste checkout e verificações executadas localmente. Inclui slices dos roadmaps 2/3, v1.5, v1.6 e v1.7; não declara esses roadmaps concluídos.

## O que está implementado

- **DI e ciclo de vida:** registry e validação antecipada de dependências, singletons e factories assíncronas concorrentes, bindings por tipo/qualifier, escopos de request e inicialização/encerramento ordenados.
- **Macros, discovery e schema:** macros para componentes/controllers, `@Entity/@ID/@Column`, Route Groups, registry de componentes/schemas por target, UUIDv7 e scaffold `HelloPearfy`.
- **Web, HTTP e Connect:** router com grupos/prefixos, IR determinístico com operation/auth metadata e refs de schema request/response, OpenAPI 3.1 filtrado por grupo, limites, admission/deadline; listener HTTP/1.1 SwiftNIO e shutdown gracioso. SDK generation permanece desligada sem discovery/diff de schemas completos.
- **Validação e segurança:** validação declarativa e por macros, API key, JWT HMAC, autenticação Bearer e autorização por roles. A validação JWT pode aceitar tokens sem `kid` somente com uma fallback key explicitamente configurada pelo app.
- **Dados e adapters:** SQL parametrizado, adapter PostgreSQL transacional e `PearfyPostgresConnectionSettings` com host/port/TLS/pool/timeout sem expor tipos PostgresNIO ao app; o client pode ser recriado depois de falha/cancelamento de start. Inclui SchemaIR/fingerprint, plano PostgreSQL inicial e migrations com catálogo JSON versionado, parâmetros, SHA-256, relatório de plan, detecção de drift e lock transacional; `PearfyTransactions` fornece unit-of-work genérica REQUIRED, rollback-only e classification de commit unknown.
- **Cache e messaging:** cache local/Redis e broker local/Redis com ack, retry, DLQ e recuperação.
- **Social v1.5 (slice inicial):** `PearfySocial` define atores, handles validados, visibilidade e contrato do grafo; `PearfySocialPostgres` persiste atores, follows e blocks, aplicando ownership, replay idempotente de actor e regras básicas de leitura. `SocialContent.swift` acrescenta contratos genéricos para post/comment/reaction/feed/notification e um worker de moderação que coordena provider e storage; adapter PostgreSQL de conteúdo/outbox ainda ausente.
- **Concorrência e integrações:** scheduler local fixed-delay; cliente HTTP outbound com limites de concorrência/fila, cancelamento, retries idempotentes e circuit breaker; cliente de chat compatível com API OpenAI.
- **Operação e extensibilidade:** health/readiness, métricas Prometheus, CLI `pearfy` com Module Manager, scaffold, primeiro `pearfy guardian verify` local (build/test/environment, sem gates completos de SQL/security/contracts) e `pearfy-bench` para profiling/benchmarks. O MCP stdio anuncia zero tools Pearfy sem grants; a única família atualmente implementada é Populate, habilitada por projeto após instalação. `pearfy ai inspect`/`modules` e Skills distribuem conhecimento estático.
- **PearfyPopulate v1.6 (slice PostgreSQL):** módulo opt-in com SchemaIR/live-schema e migration reconciliation, planner FK com ciclos explícitos, geração determinística UUIDv7/escalares, hash de plano, proteções local/staging, executor transacional em lotes com checkpoint local e replay idempotente, size target por medição PostgreSQL, `inspect/profile/plan/preview/approve/run/status/verify/report`, MCP limitado a inspeção/planejamento sem escrita no banco nem tokens de aprovação, e sync da skill oficial. Cobertura e limites em `docs/PEARFY-POPULATE.md`.
- **PearfyDevKitUI v1.7 (primeiro slice):** produto opcional com UI responsiva servida pelo app, APIs read-only protegidas por bearer token, descoberta de templates reais do router e adapter allowlisted para contadores/histogramas HTTP existentes. A UI não usa dados simulados; filtros informam quando a fonte não suporta a janela/instância solicitada. Traces, logs, queries, CPU/RSS e storage aguardam providers concretos; integração, segurança e limites estão em `docs/PEARFY-DEVKIT-UI.md`.
- **DevKit Skills-first:** Module Registry v2 separa versões de workspace, capacidades parciais e módulos planejados. `pearfy ai init/sync/inspect/doctor` instala apenas Skills dos módulos selecionados, grava versões/hashes e preserva conflitos locais; OpenCode recebe adapters do `.agents` canônico e project-local MCP começa desabilitado. `scripts/measure-ai-context.py` reporta bytes/contagens, sem estimar tokens.

Os módulos correspondentes estão declarados em `Package.swift`. Detalhes de arquitetura e limitações por área ficam em `docs/01-PLANO-DE-INTEGRACAO.md`, nos documentos `docs/02-*.md` a `docs/11-*.md`, em `docs/PEARFY-POPULATE.md` e `docs/PEARFY-DEVKIT-UI.md`.

## Testes e verificações executados

Slice Skills-first/MCP em 26/09/2026: `swift run pearfy guardian verify` passou em `swift build` e nos **141 testes unitários**. O Guardian ficou `INCOMPLETE` porque `PEARFY_TEST_POSTGRES_HOST` e `PEARFY_TEST_REDIS_HOST` não estavam configurados. `swift run pearfy ai doctor` passou todos os checks de Registry, Skills, adapters e escopo MCP. Também passaram `node --check Sources/PearfyDevKitUI/Resources/devkit.js`, `python3 -m py_compile scripts/measure-ai-context.py`, `bash scripts/check-branding.sh` e `git diff --check`. O teste MCP confirma zero tools por padrão e sete tools Populate após grant, sem ferramenta de escrita no banco nem campo de token.

Slice PearfyDevKitUI/CLI em 26/09/2026: `swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib` passou com **136 testes**. Também passaram `node --check Sources/PearfyDevKitUI/Resources/devkit.js`, `bash scripts/check-branding.sh`, `swift run pearfy sdk versions` e `swift run pearfy modules info devkit-ui`.

Atualização PearfyPopulate em 26/09/2026: `swift build` concluiu e
`bash scripts/test-unit.sh` passou com **129 testes**. Os testes PostgreSQL do
Populate são condicionais a `PEARFY_TEST_POSTGRES_HOST`; não houve conexão a um
servidor PostgreSQL nem benchmark de população nesta execução.

Atualização deste slice em 2026-09-25: `swift run pearfy guardian verify`
executou `swift build` e a suite local com **115 testes passando**. O status do
Guardian foi `INCOMPLETE` porque `PEARFY_TEST_POSTGRES_HOST` e
`PEARFY_TEST_REDIS_HOST` não estavam configurados; isso é diferente das
execuções históricas com serviços locais descritas abaixo. O Guardian atual só
cobre build/teste e checagem de variáveis de ambiente citadas pelos testes.

Executados no checkout em macOS arm64, com Apple Swift 6.4:

| Comando | Resultado |
|---|---|
| `bash scripts/test-unit.sh` | Execução histórica anterior a este slice: 101 testes passaram em Debug. No checkout atual, Guardian executou 115 testes em Debug; veja a linha seguinte. |
| `bash scripts/test-integrations.sh` | 101 testes passaram em Debug, incluindo integrações reais com PostgreSQL e Redis locais, Connect schemas, MCP read-only, Social graph, Transaction Manager e migration artifacts/plan/locking/drift. |
| `bash scripts/test-integrations.sh -c release` | Os mesmos 101 testes passaram em Release com integrações reais locais, incluindo SchemaCompiler DDL, Connect schemas, MCP read-only, transações/cancelamento, Transaction Manager, migration artifacts/plan/locking/drift, cache, broker e Social graph. |
| `swift build -c release` | Build de produção passou. |
| `bash scripts/verify-aot-snapshot.sh` | O registry AOT gerado corresponde ao snapshot versionado. |

Para repetir:

```bash
bash scripts/test-unit.sh
bash scripts/test-integrations.sh -c release
swift build -c release
bash scripts/verify-aot-snapshot.sh
```

O script de integração usa as variáveis `PEARFY_TEST_POSTGRES_*` e `PEARFY_TEST_REDIS_*`; seus padrões apontam para serviços locais. Configure esses serviços antes de executá-lo.

## Benchmarks e testes de carga registrados

Os relatórios abaixo são medições locais de 25/09/2026, no MacBook Air Apple M4, macOS 27, Swift 6.4 e build SwiftPM Release. Eles servem como referência reproduzível para a mesma máquina e configuração; não são SLAs.

- **HTTP stress:** 480.000 requisições totais comparando SwiftNIO direto e Pearfy/NIO, com plaintext/JSON e concorrência 1/10/100; todos os samples terminaram sem erros. Relatório: `Benchmarks/Baselines/HTTP-STRESS-2026-09-25-macos-arm64.md`.
- **HTTP soak e desligamento:** 60 segundos, 16 workers persistentes, 952.223 respostas HTTP 200 corretas e encerramento com SIGTERM sob tráfego, com status de saída zero. Relatório: `Benchmarks/Baselines/HTTP-SOAK-2026-09-25-macos-arm64.md`.
- **DI:** cinco amostras por cenário; a construção/validação de registry com 1.000 registros teve mediana de 9,604 ms. No teste de 100 resolves concorrentes do mesmo singleton, a factory executou uma vez. Relatório: `Benchmarks/Baselines/DI-2026-09-25-macos-arm64.md`.
- **Módulos locais:** medições de cache, broker em memória, HTTP outbound com stub, métricas e scheduler. Não representam adapters de rede ou tráfego de produção. Relatório: `Benchmarks/Baselines/MODULES-2026-09-25-macos-arm64.md`.
- **Custo de métricas HTTP:** nos cenários medidos, habilitar o middleware apresentou diferença de throughput entre −0,2% e −2,6%. Relatório: `Benchmarks/Baselines/HTTP-OBSERVABILITY-2026-09-25-macos-arm64.md`.

Scripts de benchmark e instruções de reprodução: `Benchmarks/README.md` e `scripts/benchmark-*.sh`.

## Limites conhecidos

- SSE/WebSocket, TLS, compressão, descoberta automática de controllers e binding avançado entre módulos ainda não estão implementados.
- Social Content/feed/moderação/notificações têm somente contratos core e worker genérico; ainda faltam adapter PostgreSQL, outbox durável, privacidade em consultas do feed e concorrência multi-réplica.
- `pearfy guardian verify` é um primeiro gate local de build/teste/environment; não faz enforcement de security, schema/SQL, contratos, registry ou release.
- PearfyPopulate PostgreSQL ainda suporta um alvo de cada vez e chaves primárias simples UUID/integer; pais devem existir antes do run. Triggers, RLS, partições, índices UNIQUE parciais/expressões, checks não reconhecidos, COPY, cancelamento remoto, cleanup ownership-safe e comparação PearfyMetric ainda não estão implementados. Não foi executado benchmark de 100k/2GB neste ambiente.
- Tracing distribuído e logging estruturado não têm providers concretos conectados ao DevKit; profiling contínuo e métricas detalhadas de waiters dos pools continuam pendentes.
- O soak registrado dura 60 segundos; validações prolongadas de retenção/memória, retry-storm e failover multi-host não foram concluídas.
- O workflow de CI para macOS/Linux está configurado em `.github/workflows/performance.yml`, mas seus runners remotos ainda não foram validados. Os resultados de teste deste documento são locais em macOS.
- Os roadmaps 2/3/v1.5 foram arquivados em `roadmap/`; as matrizes registram cobertura e lacunas de capacidades reutilizáveis do framework. A cópia `roadmap/estado-atual/` é um snapshot anterior aos roadmaps 2/3.

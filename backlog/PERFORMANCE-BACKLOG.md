# Backlog complementar — performance

> IDs novos não substituem IDs do backlog principal. Status atualizado contra este checkout em 2026-09-25; módulos dependentes ainda seguem pendentes.

## P0 — Enquanto DI inicial é implementada

- [ ] `PPERF-QA-001` Baseline do container atual: bootstrap/resolve/RSS, script de reprodução e metadata de host/toolchain. **Depende de:** protótipo vigente. **Progresso:** CSVs brutos e medianas com 5 runs estão em `Benchmarks/Baselines/`; falta associar um commit quando o checkout estiver versionado (`git` não está inicializado neste workspace). **Aceite:** baseline rastreável por commit.
- [x] `PPERF-DI-001` Registry congela antes do startup terminar; mutação separada de lookup por type/qualifier index. **Depende de:** `PDI-001`. **Aceite:** sem mutação após bootstrap, contextos isolados.
- [x] `PPERF-DI-002` Coalescing async singleton, sem lock durante await. **Depende de:** `PDI-003`. **Aceite:** 100 resolves → factory 1× em sucesso/falha, cancellation preservado e retry após falha.
- [x] `PPERF-DI-003` Diagnósticos de graph antes de iniciar lifecycle/listener. **Depende de:** `PDI-002`, `PDI-004`, `PCTX-001`. **Aceite:** ausente/ciclo/ambiguidades com path.
- [x] `PPERF-DI-004` Benchmark de request-scope/contexto e lifecycle. **Depende de:** `PDI-005`, `PDI-007`. **Aceite:** sem retenções após teardown; cinco amostras release e teste de liberação por weak reference em `Benchmarks/Baselines/DI-REQUEST-SCOPE-2026-09-25-macos-arm64.*`.
- [ ] `PPERF-AOT-001` Metadata estático + factories geradas sem reflection por request. **Depende de:** `PMAC-001`, `PDIS-001`. **Progresso:** registry por target e prova multi-package existem; snapshot de saída real `HelloPearfy` em `Benchmarks/Baselines/AOT-HELLOPEARFY-REGISTRY.*`. **Falta:** Git versioning e gate reproduzível de atualização do artefato.
- [ ] `PPERF-AOT-002` Benchmark build time, binary size e bootstrap do registry. **Depende de:** `PPERF-AOT-001`. **Aceite:** dados antes/depois.

## P0 — Quando Web/NIO estiver disponível

- [x] `PPERF-HTTP-001` SwiftNIO bare baseline e Pearfy plaintext/JSON equivalentes. **Depende de:** `PWEB-002`. **Aceite:** RPS, p95/p99, RSS, erros; rerun source-current em `Benchmarks/Baselines/HTTP-2026-09-25-macos-arm64-rerun.*` (cinco amostras, concorrência 1/10/100, zero erros).
- [x] `PPERF-HTTP-002` Admission control + request deadline + limites de body. **Depende de:** `PWEB-003/004`. **Aceite:** saturação controlada e body bounds; testes de 429/504.
- [ ] `PPERF-HTTP-003` Cancellation/disconnect/shutdown testados. **Depende de:** `PWEB-002/004`. **Progresso:** testes cobrem deadline, cliente cancelado/disconnect, liberação do admission slot, shutdown com oito handlers concorrentes, recuperação do listener e readiness; smoke do scaffold confirmou GET e SIGTERM. **Falta:** stress/soak em carga alta.
- [ ] `PPERF-HTTP-004` Profile de router/encoding com otimização orientada a evidência. **Depende de:** `PPERF-HTTP-001`. **Aceite:** ganho estatisticamente consistente e testes funcionais intactos.
- [ ] `PPERF-QA-002` Pipeline de benchmark sem benchmark bloquear CI por ruído alto. **Depende de:** `PPERF-QA-001`, `PPERF-HTTP-001`. **Aceite:** relatório reproduzível, alertas calibrados.

## P1 — Data, cache, filas, operação

- [ ] `PPERF-IO-001` Pool DB + fila/timeout sob overload. **Depende de:** `PDAT-001`. **Progresso:** teste real PostgreSQL limita o pool a uma conexão e executa 12 queries concorrentes, observando a recuperação; métricas de waiters, carga alta e soak ainda faltam. **Aceite:** limite observável, recuperação após saturação.
- [x] `PPERF-IO-002` Transaction cleanup em erro/cancelamento. **Depende de:** `PDAT-002`. **Aceite:** integração real confirma commit, rollback por erro/cancelamento e reutilização da conexão única em `PostgresNIO`.
- [ ] `PPERF-MEM-001` Profile de copies/allocations no JSON e buffers. **Depende de:** `PWEB-003`. **Aceite:** hotspot medido e otimização revertível.
- [ ] `PPERF-MEM-002` Soak e auditoria de ARC/cache/task retention. **Depende de:** `PPERF-HTTP-003`. **Aceite:** perfil de crescimento explicado.
- [ ] `PPERF-OBS-001` Metrics de in-flight/queue/pool/latency e cardinality control. **Depende de:** `POPS-001`. **Progresso:** registry Prometheus text limita séries/labels; middleware coleta requests, duração e HTTP in-flight; `PearfyCloud` expõe gauges outbound in-flight/queue e `PearfyCache` hits/misses/evictions/entries/bytes quando recebem registry. Pool DB, jobs queue e sinais de overload ainda não estão instrumentados. **Aceite:** overload diagnosticável.
- [ ] `PPERF-OBS-002` Medir overhead de tracing e logs. **Depende de:** `PPERF-OBS-001`. **Progresso:** comparação on/off do HTTP metrics middleware, cinco amostras e dados brutos em `Benchmarks/Baselines/HTTP-OBSERVABILITY-2026-09-25-macos-arm64.*`; tracing e structured logging ainda não existem para serem comparados. **Aceite:** relatório on/off para cada mecanismo implementado.

## P2 — Depois de evidência real

- [ ] `PPERF-AOT-003` Codecs/validators gerados para rotas críticas. **Depende de:** `PPERF-HTTP-004`. **Aceite:** ganho real sem grande regressão de build.
- [ ] `PPERF-MEM-003` Buffer lease/pool específico somente se perfil justificar. **Depende de:** `PPERF-MEM-001`. **Aceite:** nenhuma perda de isolation ou race.
- [ ] `PPERF-QA-003` Matriz cross-language Gin/Fastify/Java e variáveis controladas. **Depende de:** Pearfy HTTP estável. **Aceite:** comparação reproduzível sem ranking universal.
- [ ] `PPERF-QA-004` Benchmarks de longo prazo e budget por starter. **Depende de:** benchmarks de cada módulo. **Progresso:** microbenchmarks locais de cache, messaging, jobs, outbound HTTP stub e metrics em `Benchmarks/Baselines/MODULES-2026-09-25-macos-arm64.*`. **Falta:** Redis/DB/broker reais, soak, CI budget e changelog por starter. **Aceite:** changelog com custo operacional.

## Estado dos módulos incrementais neste checkout

Os módulos abaixo têm implementação compilável e testes unitários, mas não devem ser considerados adapters de produção até passarem os gates de integração/soak indicados:

| Módulo | Implementado | Ainda falta |
|---|---|---|
| `PearfyCache` | `CacheStore` in-memory e adapter Redis via RediStack, ambos com TTL e isolamento namespace/tenant; o local também limita entries/bytes/LRU e expõe métricas. | Profile/soak dos dois adapters e métricas Redis. |
| `PearfyMessaging` | `MessageBroker` in-memory bounded e `RedisMessageBroker` persistente com publish atômico limitado, ack/reject, retry/backoff, dedupe TTL, dead letters, recovery após restart e consumers com IDs distintos. | Jitter, failover multi-host/mesmo consumer ID, soak e política operacional Redis. |
| `PearfyJobs` | Scheduler local fixed-delay, execução sem overlap, lifecycle e cancelamento cooperativo. | Cron/time zones, persistência, distributed lock, checkpoint e workers concorrentes limitados. |
| `PearfyCloud` | Outbound HTTP com limite de concorrência/fila, cancelamento de waiter, retries somente para métodos idempotentes e circuit breaker half-open; gauges in-flight/queue opcionais. | Retry-After/jitter e teste de retry storm/soak; métricas DB/cache/jobs ainda não integradas. |
| `PearfyPostgres` | Pool PostgresNIO, lifecycle, queries parametrizadas, migration e transações; teste opt-in usa serviço PostgreSQL real. | Métricas de waiters/pool, overload/soak e matriz de drivers/plataformas. |
| `PearfyRedis` | `RedisCacheStore` com RediStack pool, TTL e namespaces; `RedisMessageBroker` usa listas/Lua para limites, ack/retry/recovery e workers distintos; testes opt-in usam Redis real. | Stress/soak, métricas próprias do broker e configuração TLS/cluster validation. |
| `PearfyAI` | Adapter de chat completions OpenAI-compatible não-streaming; HTTPS remoto obrigatório. | Streaming, tool calls, token/cost budget e integração real opt-in. |
| `PearfyObservability` | Liveness/readiness, HTTP counter/histogram/in-flight, cache counters/gauges e outbound queue gauges; Prometheus text e cardinality cap. | Metrics de DB/jobs queue, traces/logs e overhead on/off destes mecanismos. |

O roadmap principal citado em `docs/01-PLANO-DE-INTEGRACAO.md` (`docs/01-ROADMAP.md` e `docs/06-BACKLOG.md`) não existe neste checkout. O backlog acima cobre o adendo de performance; restaurar os documentos principais é necessário para afirmar cobertura de todos os itens originais.

## Paralelismo seguro

Enquanto `PDI-*` está em implementação, um agente pode trabalhar **apenas em baseline e documentação**, sem alterar as mesmas classes do container. Só abrir PR em resolução/concurrency após verificar o branch vigente, os contratos públicos e os testes existentes.

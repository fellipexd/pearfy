# Backlog complementar — performance

> IDs novos não substituem IDs do backlog principal. Status inicial: **pendente**; atualizar contra o repositório real antes de assumir tarefas.

## P0 — Enquanto DI inicial é implementada

- [ ] `PPERF-QA-001` Baseline do container atual: bootstrap/resolve/RSS, scripts de reprodução e commit/toolchain fixados. **Depende de:** protótipo vigente. **Aceite:** medições brutas e medianas com 5+ runs.
- [ ] `PPERF-DI-001` Registro congela antes de atender; separar mutation de lookup. **Depende de:** `PDI-001`. **Aceite:** sem mutação acidental após bootstrap, contextos isolados.
- [ ] `PPERF-DI-002` Coalescing async singleton, sem lock durante await. **Depende de:** `PDI-003`. **Aceite:** 100 resolves → factory chamada 1×, também em falha/cancelamento.
- [ ] `PPERF-DI-003` Diagnósticos de graph antes de listener. **Depende de:** `PDI-002`, `PDI-004`, `PCTX-001`. **Aceite:** ausente/ciclo/ambiguidades com path.
- [ ] `PPERF-DI-004` Benchmark de request-scope/contexto e lifecycle. **Depende de:** `PDI-005`, `PDI-007`. **Aceite:** sem retenções após teardown.
- [ ] `PPERF-AOT-001` Metadata estático + factories geradas sem reflection por request. **Depende de:** `PMAC-001`, `PDIS-001`. **Aceite:** prova multi-target e generated source versionado como artefato.
- [ ] `PPERF-AOT-002` Benchmark build time, binary size e bootstrap do registry. **Depende de:** `PPERF-AOT-001`. **Aceite:** dados antes/depois.

## P0 — Quando Web/NIO estiver disponível

- [ ] `PPERF-HTTP-001` SwiftNIO bare baseline e Pearfy plaintext/JSON equivalentes. **Depende de:** `PWEB-002`. **Aceite:** RPS, p95/p99, RSS, erros.
- [ ] `PPERF-HTTP-002` Admission control + request deadline + limites de body. **Depende de:** `PWEB-003/004`. **Aceite:** saturação controlada, memory bound.
- [ ] `PPERF-HTTP-003` Cancellation/disconnect/shutdown testados. **Depende de:** `PWEB-002/004`. **Aceite:** recursos liberados e health/readiness coerentes.
- [ ] `PPERF-HTTP-004` Profile de router/encoding com otimização orientada a evidência. **Depende de:** `PPERF-HTTP-001`. **Aceite:** ganho estatisticamente consistente e testes funcionais intactos.
- [ ] `PPERF-QA-002` Pipeline de benchmark sem benchmark bloquear CI por ruído alto. **Depende de:** `PPERF-QA-001`, `PPERF-HTTP-001`. **Aceite:** relatório reproduzível, alertas calibrados.

## P1 — Data, cache, filas, operação

- [ ] `PPERF-IO-001` Pool DB + fila/timeout sob overload. **Depende de:** `PDAT-001`. **Aceite:** limite observável, recuperação após saturação.
- [ ] `PPERF-IO-002` Transaction cleanup em erro/cancelamento. **Depende de:** `PDAT-002`. **Aceite:** pool sem lease órfão.
- [ ] `PPERF-MEM-001` Profile de copies/allocations no JSON e buffers. **Depende de:** `PWEB-003`. **Aceite:** hotspot medido e otimização revertível.
- [ ] `PPERF-MEM-002` Soak e auditoria de ARC/cache/task retention. **Depende de:** `PPERF-HTTP-003`. **Aceite:** perfil de crescimento explicado.
- [ ] `PPERF-OBS-001` Metrics de in-flight/queue/pool/latency e cardinality control. **Depende de:** `POPS-001`. **Aceite:** overload diagnosticável.
- [ ] `PPERF-OBS-002` Medir overhead de tracing e logs. **Depende de:** `PPERF-OBS-001`. **Aceite:** relatório on/off.

## P2 — Depois de evidência real

- [ ] `PPERF-AOT-003` Codecs/validators gerados para rotas críticas. **Depende de:** `PPERF-HTTP-004`. **Aceite:** ganho real sem grande regressão de build.
- [ ] `PPERF-MEM-003` Buffer lease/pool específico somente se perfil justificar. **Depende de:** `PPERF-MEM-001`. **Aceite:** nenhuma perda de isolation ou race.
- [ ] `PPERF-QA-003` Matriz cross-language Gin/Fastify/Java e variáveis controladas. **Depende de:** Pearfy HTTP estável. **Aceite:** comparação reproduzível sem ranking universal.
- [ ] `PPERF-QA-004` Benchmarks de longo prazo e budget por starter. **Depende de:** benchmarks de cada módulo. **Aceite:** changelog com custo operacional.

## Paralelismo seguro

Enquanto `PDI-*` está em implementação, um agente pode trabalhar **apenas em baseline e documentação**, sem alterar as mesmas classes do container. Só abrir PR em resolução/concurrency após verificar o branch vigente, os contratos públicos e os testes existentes.

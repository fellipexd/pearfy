# ADRs aditivas e anti-padrões

## ADR-PERF-001 — Não reinventar o runtime

SwiftNIO fornece event loops e I/O; Swift Concurrency fornece tasks/actors. Pearfy controla capacidade e ciclo de vida, **não implementa scheduler próprio**.

## ADR-PERF-002 — Otimização guiada por perfil

Refatoração só é performance work quando existe baseline, hipótese, métrica de sucesso, teste de correção e comparação reproduzível.

## ADR-PERF-003 — DI bootstrap-first

Factories e registries são materializados antes do atendimento; resolver singleton não avalia metadados/annotations por request.

## ADR-PERF-004 — ARC é a fonte de verdade

A biblioteca não adiciona GC ou pooling genérico de instâncias. Otimizar ownership e alocações específicas comprovadas.

## ADR-PERF-005 — Limites são parte da API operacional

Overload deve ser previsível: capacity bounds, deadline e backpressure com comportamento documentado e métricas.

## ADR-PERF-006 — Nenhum "fast path" sem segurança

Router, streaming e codecs otimizados executam as mesmas políticas de auth, validação, limites e logging mínimo dos caminhos normais.

## Não fazer

- Colocar `@unchecked Sendable` em todo container para calar compilador.
- Substituir SwiftNIO por sockets próprios para ganhar benchmarks sintéticos.
- Adicionar `Task.detached` por request sem ownership/cancellation.
- Guardar request context inteiro em singleton.
- Criar actor global para todos os handlers.
- Manter lock de thread durante `await`.
- Implementar pool de qualquer objeto sem medir lock/contention/retention.
- Usar ponteiro unsafe só porque uma execução parece mais rápida.
- Usar número de throughput de serviço alheio como SLA do Pearfy.
- Expandir DI e helpers para dentro de Core se pertencem a módulo opt-in.

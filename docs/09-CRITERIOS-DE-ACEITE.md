# Gates de aceite do adendo

## Gate P0 — DI / bootstrap (acompanha marco inicial)

- [ ] API pública e exemplos permanecem compatíveis com o roadmap vigente.
- [x] Singleton async é criado uma única vez sob 100 resoluções simultâneas.
- [x] Fábricas com erro/cancelamento acordam waiters; erro compartilhado permite retry.
- [x] Ciclos e bindings ausentes/ambíguos falham com mensagem útil; request scope é isolado por escopo e não pode ser capturado por singleton.
- [x] Contextos isolados não compartilham singleton.
- [x] Resolução não usa macro scanning/reflection por request.
- [x] Medidas repetíveis de bootstrap, resolve e RSS estão associadas ao commit local `ce5bef0` em `Benchmarks/Baselines/`.

## Gate P0 — Web / NIO (quando fase HTTP chegar)

- [x] SwiftNIO baseline semanticamente equivalente para plaintext e JSON.
- [x] Body/header bounds, timeout e deadline têm testes.
- [x] Handlers HTTP rodam fora de trabalho bloqueante no event loop.
- [x] Router/middleware e admission limit passam testes concorrentes.
- [x] HTTP errors, disconnect e shutdown sob carga passam testes extensos; testes cobrem cancelamento/disconnect, deadline, liberação do admission slot, shutdown com oito handlers concorrentes e durante 400 requisições simultâneas (32 handlers ativos), recuperação do listener e smoke de SIGTERM. Stress comparativo de 480 mil requisições passou sem erros. Soak prolongado é acompanhado no gate de memória.
- [x] p95/p99, RPS, RSS e erros foram medidos em concorrências 1/10/100; rerun source-current de cinco amostras em `Benchmarks/Baselines/HTTP-2026-09-25-macos-arm64-rerun.*`.

## Gate P1 — Data / integração

- [ ] Pool limita conexões e fila; teste PostgreSQL real fixa o pool em uma conexão e exercita 12 operações concorrentes, mas waiters observáveis e overload/soak de alta carga faltam.
- [x] Transação limpa recurso em sucesso, erro e cancelamento; teste PostgreSQL real confirma reutilização da única conexão após rollback.
- [ ] Redis cache e `RedisMessageBroker` passaram testes reais de TTL, isolamento, capacity, ack/retry, dead letter, restart recovery e dois consumer IDs; faltam retry-storm/soak e failover multi-host sob falhas. Client HTTP limita concorrência/fila e retries a métodos idempotentes, com cancelamento e circuit breaker testados; falta carga/soak.
- [ ] Traces e métricas identificam gargalo sem vazamento de dados.

## Gate 1.0 transversal

- [ ] CI Linux/macOS release build + testes. Workflow está configurado em `.github/workflows/performance.yml`; falta execução remota nos dois runners.
- [ ] Soak e saturation não deixam crescimento inexplicado de memória.
- [ ] Benchmarks com metodologia e dados brutos publicáveis.
- [ ] Performance não enfraqueceu auth, validação, limites ou isolation.
- [ ] Overhead de módulos opcionais documentado quando habilitados.
- [ ] Qualquer feature ainda experimental aparece como tal.

## Critério de reversão

Reverter otimização se produzir regressão estatisticamente consistente em p99, aumento de erro, duplicação de factory, memory leak, race, data leak, falha de cancelamento ou API frágil sem ganho comprovado.

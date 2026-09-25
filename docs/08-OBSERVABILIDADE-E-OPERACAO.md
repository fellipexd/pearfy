# Observabilidade da performance

## Métricas

- `pearfy_http_requests_total` por método, template de rota, status class e motivo de rejeição.
- Histogramas de latência de request e outbound, sem labels de ID de usuário ou URL completa.
- In-flight requests, admission queue length, timeouts, cancellations, rejected requests.
- Estado dos pools DB/HTTP; in-use/idle/waiters e tempo de espera.
- Lifecycle startup, readiness e shutdown; falhas de factory/DI.
- RSS, CPU, tasks e event loop lag quando ferramenta/platform adapter suportar medição confiável.

**Implementado:** `MetricsRegistry` agrega counters/gauges/histograms em formato Prometheus text e impõe limites de séries/labels. `HTTPMetricsMiddleware` registra request total/duração por método, status class e route template, além de gauge in-flight por método/template. `PearfyCloud` pode publicar gauges outbound in-flight/queue; `PearfyCache` publica hits/misses/evictions/entries/bytes; `PearfyPostgres` publica operações in-flight/duração/erros, todos por registry injetado. O overhead on/off do middleware HTTP foi medido em `Benchmarks/Baselines/HTTP-OBSERVABILITY-2026-09-25-macos-arm64.*`. `HealthRegistry`, `ReadinessGate` e `/health/live`, `/health/ready` fornecem health/readiness com timeout e cancelamento cooperativo de probes; `/metrics` requer rota authenticated. Waiters detalhados do pool DB, jobs queue, tracing distribuído, logging estruturado e profiling contínuo ainda não estão conectados.

## Regras

- Instrumentação é opt-in por starter quando gerar dependências pesadas, mas health mínimo pertence ao runtime HTTP.
- Diagnósticos internos são protegidos; sem secrets, tokens, SQL contendo dados sensíveis ou IDs de alta cardinalidade.
- Validar custo do tracing com sampling ativo e desativado.
- Não interpretar aumento de latência causado por gerador de carga como evento real do servidor.
- Sinais de overload devem aparecer em métricas, logs e resposta HTTP quando apropriado.

## CLI disponível e comandos planejados

O scaffold e os wrappers operacionais estão implementados: `pearfy new` gera projeto, `pearfy benchmark` roda o baseline, `pearfy profile` delega ao profiler nativo disponível e `pearfy doctor performance` informa capacidades do host. `pearfy-bench` continua disponível como executable direto. O smoke test atual criou, compilou, consultou `/hello/pear` e encerrou o app gerado por SIGTERM.

```text
pearfy new my-api
pearfy-bench
```

```text
pearfy benchmark
pearfy profile cpu
pearfy profile memory
pearfy doctor performance
```

Benchmarkar o custo de métricas HTTP com middleware ligado/desligado:

```bash
bash scripts/benchmark-observability.sh --runs 5 --http-requests 500
bash scripts/benchmark-modules.sh --runs 5 --resolves 1000 --concurrency 10
```

Os comandos de profiling/doctor deverão integrar profilers e recursos disponíveis no host; não inventar uma API universal que funcione igualmente em todas as versões de macOS/Linux.

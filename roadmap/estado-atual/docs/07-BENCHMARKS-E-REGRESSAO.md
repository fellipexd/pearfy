# Pearfy Performance Lab — plano de medição

## Primeira entrega

Criar uma baseline **no código vigente** antes de otimizar. Uma comparação sem hardware, build e workload controlados não fundamenta decisões de arquitetura.

**Implementado neste checkout:** baselines DI/HTTP release com CSV bruto e metadata em `Benchmarks/Baselines/`; o experimento de type index e request scope compara cinco amostras. `pearfy-bench` inclui request scope cached/create-close, lifecycle vazio, SwiftNIO bare versus router Pearfy plaintext/JSON e microbenchmarks locais de módulos (`MODULES-2026-09-25-macos-arm64.*`). O rerun HTTP source-current em `HTTP-2026-09-25-macos-arm64-rerun.*` registrou zero erros e variação de throughput entre −3.8% e −12.6% nos workloads medidos; a diferença de −12.6% no JSON com concorrência 1 permanece como sinal para profiling, não como justificativa para otimização sem perfil. A comparação on/off do HTTP metrics middleware em `HTTP-OBSERVABILITY-2026-09-25-macos-arm64.*` registrou −0.2% a −2.6% RPS nesta amostra local. Cenários Redis/DB real, broker externo, WebSocket, soak, allocações e profiling continuam pendentes. Reproduza com `bash scripts/benchmark-di.sh`, `bash scripts/benchmark-http.sh`, `bash scripts/benchmark-observability.sh` e `bash scripts/benchmark-modules.sh`.

## Comparadores

- Pearfy/Swift: build `release`, sem instrumentation invasiva.
- SwiftNIO puro: mesma rota e semântica, para medir overhead do framework.
- Go/Gin, Node/Fastify e Java 25/framework JVM: referências externas opcionais, em versões e configuração documentadas. Não presumir vencedor.

## Cenários e ordem

1. `GET /plaintext`: mínimo HTTP, payload fixo e keep-alive.
2. `GET /json`: DTO simples com mesmo conteúdo e encoding.
3. `GET /route/{id}`: path binding e validação.
4. `POST /validate`: corpo JSON, validação e erro inválido.
5. `GET /users/{id}`: PostgreSQL com pool igual e dataset idêntico.
6. `POST /transfer`: transação com 2 writes, rollback e isolamento.
7. `GET /cache/{id}`: Redis e alternativa em memória separadas.
8. `WebSocket`: conexões sustentadas com mensagens pequenas.
9. CPU-bound: serviço de cálculo, sem I/O, para medir overhead e escalabilidade.

Os cenários 5–9 só entram após respectivos módulos existirem. Banco, cache e rede externos devem ser contabilizados. Registrar tipo de hardware, kernel, frequência CPU, throttling, NUMA se relevante, RTT, pool e payload.

## Métricas

- RPS ou operações/s, p50/p95/p99 (ms), contagem/tipo de erro.
- RSS em idle, peak RSS, CPU%, bytes/alocações por operação quando mensurável, tarefas/in-flight, fila e conexões.
- Cold start e readiness, tamanho de binário e imagem Docker.
- Latência sob saturation, rollback/cancellation leak, RSS após soak.
- Distribuição por pelo menos 5 execuções (preferencialmente 10), mediana e dispersão; repetir sob mesma configuração.

## Protocolo reprodutível

1. Fixar commit, toolchain e versões das dependências; usar `swift build -c release`.
2. Isolar servidor e gerador de carga em hosts/processos quando necessário; calibrar o próprio gerador.
3. Registrar warm-up ou sua ausência; manter duração e concorrências idênticas.
4. Executar testes com 1, 10, 100, 500 e 1000 conexões **se suportadas com segurança pelo ambiente**; registrar o limite real.
5. Separar medição de idle, throughput máximo, saturação e soak (ex.: 30–60 min) em relatórios distintos.
6. Exportar JSON/CSV de resultados com metadata e guardar artefatos de CI; não publicar só screenshot de RPS.
7. Alterar **uma variável por experimento** e comparar baselines do mesmo ambiente.

## Budget de regressão proposto

- Definir guardrails por benchmark a partir do baseline real e ruído estatístico. Não fixar um único número universal.
- Inicialmente, alertar se queda de throughput ou aumento de p99/RSS exceder ~10% frente à mediana das últimas execuções estáveis, **desde que a variação natural do ambiente seja menor**.
- Teste funcional e segurança reprovam PR independentemente do resultado de benchmark.

## Formato mínimo do relatório

```text
commit | toolchain | OS | CPU/RAM | build flags | scenario | payload
concurrency | duration | warmup | RPS | p50/p95/p99 | failures
RSS idle/peak | CPU | allocs (if available) | notes | baseline commit
```

## Atenção ao homelab

Um servidor doméstico é útil para regressão comparativa, mas ruído de outros contêineres, temperatura, governor e rede inviabiliza conclusões muito pequenas. Comparar na mesma máquina, com ambiente e versões fixados, e repetir antes de decidir refatorações.

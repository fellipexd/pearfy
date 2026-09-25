# Pearfy Performance Lab

## Baseline DI

Rode a partir da raiz do pacote. O comando usa build `release`, mede cinco rodadas por padrão e emite CSV no `stdout`; metadata da máquina e do toolchain vai para `stderr`.

```bash
bash scripts/benchmark-di.sh > di-baseline.csv 2> di-baseline-metadata.txt
```

Para uma rodada curta de desenvolvimento, reduza o número de amostras/iterações sem usá-la como baseline publicada:

```bash
bash scripts/benchmark-di.sh --runs 2 --registrations 10,100 --resolves 1000 --concurrency 20
```

Os cenários cobrem construção/validação do registry com 10, 100 e 1.000 registrations, qualified/primary lookup escalado, resolve singleton repetido, transient e 100 resolves concorrentes sobre uma única factory singleton. Para lookup escalado, o número de operações usa `min(--resolves, max(100, 100000 / registrations))` para manter o baseline da implementação inicial de complexidade linear finito. `peak_rss_bytes` é o high-water RSS do processo medido com `getrusage`; não é memória por operação.

Baselines versionadas e comparação do type index ficam em `Baselines/`. O CSV de lookup antes/depois usa o mesmo host/toolchain e cinco amostras por ponto; consulte o relatório adjacente para limites de interpretação.

## Baseline HTTP

O runner compara rotas plaintext e JSON semanticamente iguais entre SwiftNIO direto e o router Pearfy/NIO. O baseline local mediu RPS, p95/p99, RSS e erros com concorrência 1/10/100 em cinco amostras. Os resultados são experimentais; rode em host dedicado antes de tomar decisões de release.

```bash
bash scripts/benchmark-http.sh --runs 5 --http-requests 500 > http-baseline.csv 2> http-baseline-metadata.txt
```

Repita pelo menos cinco vezes em host e configuração controlados. Preserve CSV e metadata juntos; não compare execuções de máquinas/toolchains diferentes como se fossem equivalentes. A ferramenta não altera o runtime e não afirma que medições locais constituem SLA.

## High-load run e profiling

O registro `Baselines/HTTP-STRESS-2026-09-25-macos-arm64.*` compara 480.000 requests no total (20.000 por amostra, duas rodadas e concorrência 1/10/100). É um teste local de carga, não um soak prolongado. Reproduza com:

```bash
bash scripts/benchmark-http.sh --runs 2 --http-requests 20000
```

No macOS sem Xcode, capture uma amostra de CPU do benchmark e do servidor/router durante o tráfego:

```bash
PEARFY_PROFILE_DURATION_SECONDS=30 swift run -c release pearfy profile cpu -- \
  .build/release/pearfy-bench --http-only --runs 1 --http-requests 10000
```

O resultado de `/usr/bin/sample` é escrito no diretório de saída configurado por `PEARFY_PROFILE_OUTPUT_DIR` (ou no diretório atual). A captura sob carga deste host mostrou frames do router, middleware, path matching e `JSONEncoder`; use-a para investigação, não como medição de throughput.

Com `/usr/bin/heap` disponível, um snapshot de classes/allocation sites pode ser obtido durante o benchmark habilitando `MallocStackLogging=lite`; um exemplo e as ressalvas de atribuição estão em `Baselines/HTTP-ALLOCATIONS-2026-09-25-macos-arm64.md`. O comando `pearfy profile memory` continua reportando RSS via `ps` neste host.

Para testar tráfego contínuo e SIGTERM sob carga, `scripts/soak-http.py` inicia um executável HTTP, dispara clientes persistentes, mede RSS e termina o servidor enquanto ainda recebe tráfego. O registro de 60 segundos está em `Baselines/HTTP-SOAK-2026-09-25-macos-arm64.md`.

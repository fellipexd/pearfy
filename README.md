# Pearfy — adendo de performance ao roadmap (v1.1)

> **Adendo complementar e incremental** ao roadmap principal. Não renumera os marcos 0.1–1.0 nem substitui contratos já aceitos; as implementações deste checkout correspondem às issues PPERF concluídas descritas abaixo.

## Finalidade

Adicionar um eixo de **performance by design** à execução do roadmap existente: menos trabalho por requisição, limites de recursos e concorrência, otimizações mensuráveis e diagnóstico operacional. Aproveita ideias do Go, Rust, Java e Node.js sem transplantar runtimes ou reescrever SwiftNIO, ARC ou o scheduler de Swift.

**Estado inicial assumido:** o primeiro roadmap está em implementação. No protótipo anterior, `ServiceContainer` usa `NSRecursiveLock` e factories síncronas; isso **não equivale a dizer que a implementação atual do usuário permanece assim**. Inspecionar o código vigente antes de aplicar qualquer issue deste adendo.

## Ordem de leitura

1. `docs/01-PLANO-DE-INTEGRACAO.md` — como anexar ao projeto em andamento sem recomeçar.
2. `docs/02-ARQUITETURA-DE-PERFORMANCE.md` — fronteiras de responsabilidade e decisões.
3. `docs/03-DI-E-BOOTSTRAP-AOT.md` — resolução de componentes e geração antecipada.
4. `docs/04-CONCORRENCIA-E-BACKPRESSURE.md` — limites, cancelamento e filas.
5. `docs/05-MEMORIA-E-OWNERSHIP.md` — ARC, buffers e recursos.
6. `docs/06-HTTP-E-SERIALIZACAO.md` — caminho crítico da requisição.
7. `docs/07-BENCHMARKS-E-REGRESSAO.md` — metodologia e métricas.
8. `docs/08-OBSERVABILIDADE-E-OPERACAO.md` — visibilidade em produção.
9. `docs/09-CRITERIOS-DE-ACEITE.md` — gates por marco e não-regressão.
10. `docs/10-DECISOES-E-ANTI-PADROES.md` — ADRs complementares.
11. `docs/11-IDEIAS-DE-OUTROS-ECOSSISTEMAS.md` — mapeamento de referências.
12. `backlog/PERFORMANCE-BACKLOG.md` — issues identificadas e dependências.
13. `integration/PROMPT-PARA-AGENTE.md` — instrução pronta para implementação incremental.
14. `integration/CHANGESET.md` — arquivos a acrescentar sem sobrescrever os existentes.

## Contratos preservados

- Pearfy como nome e identidade exclusivos no código-fonte.
- Swift 6.x com strict concurrency, macOS e Linux, Swift Package Manager.
- `@Autowired` / `@Inject` como ergonomia sobre injeção na construção; sem `T!` nem resolve global por getter.
- Discovery estático multi-target como meta, sem alegar que macro isolada varre todo o pacote.
- HTTP e dependências de infraestrutura fora de Core/DI/Context.
- Segurança, observabilidade e testes continuam transversais; performance não justifica remoção de verificações.

## Implementação deste checkout

Este checkout implementa DI/request scopes, contexto e lifecycle; HTTP/NIO, validação e políticas JWT/API-key; SQL parametrizado e adapter PostgreSQL; cache local e Redis; broker em memória e Redis; scheduler local de fixed-delay; client HTTP outbound com concorrência/fila limitadas, retry/circuit breaker; adapter de chat OpenAI-compatible; e health/readiness/métricas Prometheus. O escopo e as limitações atuais de cada módulo estão em `backlog/PERFORMANCE-BACKLOG.md` e nos documentos por área. `pearfy new` gera um app HTTP executável; `pearfy-bench` mede DI, HTTP, observability e adapters locais.

Os CSVs em `Benchmarks/Baselines/` são medições locais, não SLAs. Este workspace não possui `.git`, então `PPERF-QA-001` continua aberto até os dados serem associados a um commit. O arquivo-fonte do roadmap principal citado pelos documentos (`docs/01-ROADMAP.md`, além de `docs/06-BACKLOG.md`) não está presente neste checkout; o adendo de performance está disponível, mas o aceite global do roadmap original não pode ser conferido sem esses documentos. `benchmark-observability.sh` compara métricas HTTP ligadas/desligadas; `benchmark-modules.sh` mede adapters locais em memória/stub.

A suíte tem 72 testes; as quatro verificações com serviços externos rodam quando configuradas. A suíte foi executada em macOS com PostgreSQL e Redis locais habilitados, e passou em Debug e Release:

```bash
swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test -c release -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

Para rodar incluindo as integrações locais, inicie PostgreSQL/Redis e use `bash scripts/test-integrations.sh` (aceita `PEARFY_TEST_POSTGRES_*` e `PEARFY_TEST_REDIS_*`).

Gates externos ainda pendentes: Git para associar/versionar baselines, host profiler (`xctrace` indisponível neste host), Linux CI, soak e validação do broker em múltiplos processos/hosts. PostgreSQL/Redis têm adapters e testes de integração locais. O roadmap principal não está neste checkout; a cobertura aqui é do adendo de performance.

## CLI disponível

```bash
swift run pearfy new minha-api
cd minha-api
swift build
swift run MinhaApi
swift run pearfy benchmark
bash scripts/benchmark-observability.sh --runs 5 --http-requests 500
bash scripts/benchmark-modules.sh --runs 5 --resolves 1000 --concurrency 10
swift run pearfy profile cpu -- ./MinhaApi
swift run pearfy doctor performance
```

O scaffold usa um caminho local absoluto para este checkout do Pearfy; `--framework-path` ou `PEARFY_FRAMEWORK_PATH` escolhem outro checkout. Profiling depende das ferramentas host (`xcrun xctrace`, `perf`, `heaptrack` ou `valgrind`). Veja `swift run pearfy --help`.

## Regra de nomenclatura

Comparações com Spring Boot podem aparecer exclusivamente em documentação `.md`. Em novos arquivos de código, testes, scripts, manifests, workflows e nomes de símbolos, usar apenas Pearfy e nomenclatura técnica neutra.

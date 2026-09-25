# Pearfy — adendo de performance ao roadmap (v1.1)

> **Pacote complementar e incremental**. Não substitui `Pearfy-roadmap.zip`, não altera `Package.swift`, `Sources/`, `Tests/`, decisões já aceitas, nem marca tarefas antigas como concluídas.

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

## Escopo deste ZIP

É um **plano executável por issues**, não uma atualização do framework compilável. Não contém reimplementação prematura de runtime, código Swift que sobrescreva o protótipo, nem benchmark falsamente apresentado como executado. Exemplos e configurações nos `.md` são propostas para quando seus módulos existirem.

## Regra de nomenclatura

Comparações com Spring Boot podem aparecer exclusivamente em documentação `.md`. Em novos arquivos de código, testes, scripts, manifests, workflows e nomes de símbolos, usar apenas Pearfy e nomenclatura técnica neutra.

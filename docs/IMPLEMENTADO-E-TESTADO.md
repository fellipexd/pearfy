# Pearfy — implementação e testes

**Atualizado em:** 25 de setembro de 2026

**Escopo:** funcionalidades presentes neste checkout e verificações executadas localmente. Este documento descreve o adendo de performance; não declara concluído o roadmap original do Pearfy.

## O que está implementado

- **DI e ciclo de vida:** registry e validação antecipada de dependências, singletons e factories assíncronas concorrentes, bindings por tipo/qualifier, escopos de request e inicialização/encerramento ordenados.
- **Macros e discovery AOT:** macros para componentes e controllers, plugin gerador de registry por target e scaffold `HelloPearfy`.
- **Web e HTTP:** router, parâmetros de rota/query/header/body, middleware, OpenAPI 3.1 inicial, limites de body/headers, controle de admissão e deadline; listener HTTP/1.1 baseado em SwiftNIO e shutdown gracioso.
- **Validação e segurança:** validação declarativa e por macros, API key, JWT HMAC, autenticação Bearer e autorização por roles.
- **Dados e adapters:** SQL parametrizado, migrations e adapter PostgreSQL com transações; cache local e Redis; broker local e Redis com limites, acknowledgements, retry, dead letters e recuperação após restart.
- **Concorrência e integrações:** scheduler local fixed-delay; cliente HTTP outbound com limites de concorrência/fila, cancelamento, retries idempotentes e circuit breaker; cliente de chat compatível com API OpenAI.
- **Operação:** health/readiness, métricas Prometheus com limites de cardinalidade, CLI `pearfy`, scaffold de aplicações e executável `pearfy-bench` para benchmarks e profiling.

Os módulos correspondentes estão declarados em `Package.swift`. Detalhes de arquitetura e limitações por área ficam em `docs/01-PLANO-DE-INTEGRACAO.md` e nos documentos `docs/02-*.md` a `docs/11-*.md`.

## Testes e verificações executados

Executados no checkout em macOS arm64, com Apple Swift 6.4:

| Comando | Resultado |
|---|---|
| `bash scripts/test-unit.sh` | 73 testes passaram em Debug. Neste comando os hosts de PostgreSQL e Redis não estavam configurados, então as rotinas de integração externa retornaram sem conectar aos serviços. |
| `bash scripts/test-integrations.sh -c release` | 73 testes passaram em Release; integrações reais com PostgreSQL e Redis locais passaram, incluindo transações/cancelamento, cache, broker, limites, retry, dead letters e recuperação. |
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
- Tracing distribuído, logging estruturado, profiling contínuo e métricas detalhadas de waiters dos pools ainda estão pendentes.
- O soak registrado dura 60 segundos; validações prolongadas de retenção/memória, retry-storm e failover multi-host não foram concluídas.
- O workflow de CI para macOS/Linux está configurado em `.github/workflows/performance.yml`, mas seus runners remotos ainda não foram validados. Os resultados de teste deste documento são locais em macOS.
- O roadmap original (`docs/01-ROADMAP.md` e `docs/06-BACKLOG.md`) não está neste checkout; portanto, o estado global daquele roadmap não pode ser confirmado aqui.

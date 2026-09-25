# Pearfy — implementação e testes

**Atualizado em:** 25 de setembro de 2026

**Escopo:** funcionalidades presentes neste checkout e verificações executadas localmente. Inclui slices dos roadmaps 2/3 e v1.5; não declara esses roadmaps concluídos.

## O que está implementado

- **DI e ciclo de vida:** registry e validação antecipada de dependências, singletons e factories assíncronas concorrentes, bindings por tipo/qualifier, escopos de request e inicialização/encerramento ordenados.
- **Macros, discovery e schema:** macros para componentes/controllers, `@Entity/@ID/@Column`, Route Groups, registry de componentes/schemas por target, UUIDv7 e scaffold `HelloPearfy`.
- **Web, HTTP e Connect:** router com grupos/prefixos, snapshot de contrato routes-only, OpenAPI 3.1 filtrado por grupo, limites, admission/deadline; listener HTTP/1.1 SwiftNIO e shutdown gracioso.
- **Validação e segurança:** validação declarativa e por macros, API key, JWT HMAC, autenticação Bearer e autorização por roles.
- **Dados e adapters:** SQL parametrizado, adapter PostgreSQL transacional, SchemaIR/fingerprint, plano PostgreSQL inicial e migrations com SHA-256, relatório de plan, detecção de drift e lock transacional; `PearfyTransactions` fornece unit-of-work genérica REQUIRED, rollback-only e classification de commit unknown.
- **Cache e messaging:** cache local/Redis e broker local/Redis com ack, retry, DLQ e recuperação.
- **Social v1.5 (slice inicial):** `PearfySocial` define atores, handles validados, visibilidade e contrato do grafo; `PearfySocialPostgres` persiste atores, follows e blocks, aplicando ownership e regras básicas de leitura.
- **Concorrência e integrações:** scheduler local fixed-delay; cliente HTTP outbound com limites de concorrência/fila, cancelamento, retries idempotentes e circuit breaker; cliente de chat compatível com API OpenAI.
- **Operação e extensibilidade:** health/readiness, métricas Prometheus, CLI `pearfy` com Module Manager para produtos disponíveis, scaffold e `pearfy-bench` para profiling/benchmarks.

Os módulos correspondentes estão declarados em `Package.swift`. Detalhes de arquitetura e limitações por área ficam em `docs/01-PLANO-DE-INTEGRACAO.md` e nos documentos `docs/02-*.md` a `docs/11-*.md`.

## Testes e verificações executados

Executados no checkout em macOS arm64, com Apple Swift 6.4:

| Comando | Resultado |
|---|---|
| `bash scripts/test-unit.sh` | 98 testes passaram em Debug; integrações externas sem ambiente configurado retornam sem conectar aos serviços. |
| `bash scripts/test-integrations.sh` | 98 testes passaram em Debug, incluindo integrações reais com PostgreSQL e Redis locais, Social graph, Transaction Manager e migration plan/locking/drift. |
| `bash scripts/test-integrations.sh -c release` | Os mesmos 98 testes passaram em Release com integrações reais locais, incluindo SchemaCompiler DDL, transações/cancelamento, Transaction Manager, migration plan/locking/drift, cache, broker e Social graph. |
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
- Os roadmaps 2/3/v1.5 foram arquivados em `roadmap/`; as matrizes registram cobertura e lacunas de capacidades reutilizáveis do framework. A cópia `roadmap/estado-atual/` é um snapshot anterior aos roadmaps 2/3.

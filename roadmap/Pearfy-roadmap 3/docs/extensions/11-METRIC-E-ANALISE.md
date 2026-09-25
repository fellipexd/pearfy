# 11 — PearfyMetric: analytics de performance e regressão

Módulo opcional `pearfy add metric`. Consome telemetry (PearfyObservability) mas fornece valor sem IA. `PearfyMetricAI` é um complemento que utiliza profile do PearfyAI central, não provedor embutido.

## Escopos monitorados

| Componente | Medidas sugeridas |
|---|---|
| HTTP por route-template/método | throughput, error rate, avg, histogram/p50/p95/p99 |
| Use case `@Measured` | count/duração/sucesso/falha/cancelamento |
| PearfyData query normalizada | count/duração/timeout, rows se driver suporta, plano somente opt-in |
| TransactionManager | commit/rollback, tempo total, lock wait quando driver mede, retry/classificação |
| WebSocket/gRPC | conexões/streams, deadlines, status, latência |
| Jobs/Webhooks | backlog, queue wait, attempts, poison/duplicates |
| PearfyAI | provider/profile, duração, tokens quando disponíveis, custo estimado sem prompt |
| Runtime | CPU/RSS, pool saturado, task pressure quando suportado |

Média não substitui percentis; histogramas agregados entre instâncias (NÃO média dos p95 por réplica). Para duração avg usar soma/count; taxas calculadas com denominador/janela corretos. Regressão exige comparações por deploy, janela e volume; se amostra insuficiente, diagnóstico inconclusivo.

## Queries

Usar query-shape normalizada, statement type e **nunca bind values**; labels de cardinalidade limitada. N+1 = hipótese apoiada por aumento de queries por use case, não veredito automático. Lock wait só atribuir se instrumento mediu; não inferir causa a partir de latência geral.

## API/CLI-alvo

```swift
@Measured("payments.transfer")
func transfer(_ input: TransferInput) async throws -> TransferResult { /* ... */ }
```

```bash
pearfy metric routes
pearfy metric inspect payments.transfer
pearfy metric queries --sort total-time
pearfy metric compare --before v1.4 --after v1.5
pearfy metric analyze payments.transfer --ai local
```

A última opção escolhe o **destino de análise autorizado** entre profiles configurados no backend, não instala provider e não sobrescreve política de dados.

## Diagnóstico

Relatórios estruturados: evidência, hipótese, grau de cobertura, sinais faltantes, impacto, sugestão testável; IA não faz alteração em produção automaticamente. Guardian pode localizar revisão e gerar proposta submetida aos mesmos testes/budget e revisão humana.

## SLO e alertas

Implementar alertas com condição/window/baseline/quorum e cooldown. Evitar alertar por uma única amostra rara; nenhuma afirmação de “causa comprovada” sem instrumentação correspondente.

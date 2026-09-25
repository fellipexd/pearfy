# 10 — PearfyObservability: instrumentação e correlação

Responsabilidade: produzir/correlacionar traces, métricas e logs; integração com OpenTelemetry e propagação entre rotas, use cases, SQL, gRPC, WS, jobs, AI e integrações externas. Não duplicar as responsabilidades de análise avançada do PearfyMetric nem de sink do PearfyLogs.

## Design

- Contexto de trace/request correlacionável sem dados de negócio sensíveis; propagation compatível W3C trace context quando apropriado.
- Auto instrumentar middleware HTTP e calls gerenciadas pelo framework; `@Measured` do Metric e instrumentação específica compõem o mesmo contexto.
- Percentis estimados por histogramas; traces podem ser amostrados, mas contadores/histogramas devem seguir política de coleta separada.
- IDs dinâmicos não são labels; templates e nomes lógicos estáveis. Controlar sampling, tamanho, batching e memory/backpressure.
- Exportador neutro OTLP e console dev; preferir Collector/Alloy e presets ao invés de código de negócio vendor-specific.

## Integração

```text
Swift request → trace context → PearfyLogs correlation
                           ↘ histogramas/contadores → PearfyMetric aggregations
                           ↘ OTLP → Collector/Alloy → dashboards/backends
```

## Maturidade Swift

Antes de fixar versões ou chamar APIs de metrics SDK do OpenTelemetry Swift, consultar release vigente e validar com compiler alvo. Isolar instrumentação por protocolos para permitir evolução de packages. Nenhuma promessa de API estável baseada apenas em roadmap.

## Gate

Request de teste correla spans/logs em worker; sem dados pessoais em atributos exportados; cancelamentos, retries, locks e exceptions classificados; overhead comparado baseline com instrumentação off/on; collector offline não interrompe negócio.

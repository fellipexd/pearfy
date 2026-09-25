# Exemplo conceitual — AI central, Logs e Metric

```yaml
pearfy:
  ai:
    providers:
      local: { type: ollama, endpoint: "${OLLAMA_URL}" }
    profiles:
      crm-analysis:
        provider: local
        model: "${CRM_MODEL}"
        data-policy: crm-minimized
        cloud-fallback: false
  crm:
    insights:
      ai-profile: crm-analysis
  logs:
    format: json
    privacy: { mode: strict }
    outputs:
      stdout: { enabled: true }
      otlp: { enabled: true, endpoint: "${OTEL_EXPORTER_OTLP_ENDPOINT}" }
  metric:
    capture: { routes: true, usecases: true, queries: true, retries: true }
    ai: { profile: metrics-diagnostics, cloud-export-approved: false }
```

O profile `metrics-diagnostics` também deve estar declarado em `pearfy.ai.profiles` antes de ligar análise por IA. Config schema/fail-fast valida esse requisito.

```text
Pearfy HTTP + Data + UseCases
  ├─ PearfyLogs → privacy → stdout JSON / OTLP → collector → Loki/Datadog
  └─ PearfyObservability → PearfyMetric → histogram/regression
                                       → aggregate/privacy → PearfyAI profile
```

Exemplo de relatório para modelo sem dados sensíveis:

```json
{
  "schemaVersion": 1,
  "operation": "payments.transfer",
  "window": "15m",
  "requestCount": 12540,
  "durationMs": { "avg": 48, "p95": 112, "p99": 290 },
  "errorRate": 0.008,
  "retryRate": 0.032,
  "evidence": ["db_wait_increased"],
  "coverage": { "lockWaitMeasured": false }
}
```

A IA NÃO pode afirmar causa `lock contention` quando `lockWaitMeasured=false`; pode sugerir instrumentação adicional. Valores ilustrativos.

# 23 — CLI e configurações — referência consolidada

Comandos são **propostas** e requerem implementação/ajuste à CLI que de fato existe.

```bash
# Módulos
pearfy modules list
pearfy modules plan --add backoffice
pearfy add backoffice
pearfy add approvals
pearfy add crm
pearfy add ai
pearfy add crm-insights
pearfy add logs
pearfy logs connect grafana
pearfy logs connect datadog
pearfy add metric
pearfy add jobs --store postgres
pearfy add webhooks
pearfy add messaging
pearfy add whatsapp
pearfy add telegram
pearfy add chatbot
pearfy add integrations
pearfy modules doctor

# AI configuração central / diagnóstico
pearfy ai providers list
pearfy ai profile validate crm-analysis
pearfy metric routes
pearfy metric analyze payments.transfer --ai local
pearfy metric privacy check --target cloud
pearfy logs doctor

# SDK/artefatos v1.3
pearfy sdk generate --group backoffice
pearfy export postman --group backoffice
pearfy export curl --group backoffice

# Blueprints
pearfy blueprint add bko-crm --dry-run
```

## Exemplo de configuração integrada (conceitual)

```yaml
pearfy:
  ai:
    providers:
      local:
        type: ollama
        endpoint: "${OLLAMA_URL}"
    profiles:
      crm-analysis:
        provider: local
        model: "${CRM_MODEL}"
        cloud-fallback: false
      metrics-diagnostics:
        provider: local
        model: "${METRIC_MODEL}"
        cloud-fallback: false
  crm:
    insights:
      ai-profile: crm-analysis
  metric:
    privacy:
      mode: strict
      capture-request-bodies: false
      capture-response-bodies: false
      capture-sql-parameters: false
    ai:
      profile: metrics-diagnostics
      cloud-export-approved: false
  logs:
    format: json
    privacy:
      mode: strict
    outputs:
      stdout:
        enabled: true
      otlp:
        enabled: true
        endpoint: "${OTEL_EXPORTER_OTLP_ENDPOINT}"
```

**Nunca copiar secrets reais para `.md`, SDK, collection Postman ou cURL.** As chaves/valores são sugestões de schema; definir precedence config/env/secret manager e validar contra structs reais no CLI.

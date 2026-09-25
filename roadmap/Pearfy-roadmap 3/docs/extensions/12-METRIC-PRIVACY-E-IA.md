# 12 — Privacy gate e PearfyMetricAI

Regra: **antes do prompt** e antes de qualquer exportação, criar um novo payload de análise via allowlist explícita de métricas agregadas. Não enviar raw traces/logs, endpoint concreto, input/output HTTP, raw SQL/params, conversation content, saldos, tokens, nomes, CPF, e-mail nem stack trace bruto por padrão.

## Fluxo

```text
Telemetria → agregação local → janela/supressão → allowlist → privacy check
 → pacote versionado e auditável → PearfyAI profile local/cloud autorizado
 → diagnóstico como hipótese + evidência → PearfyGuardian review opcional
```

- Redação baseada em regex é camada auxiliar, nunca justificativa para coletar dado sensível e “limpar depois”.
- Mínimo de amostras é controle de risco configurável e NÃO prova de anonimização; combinar generalização, cardinalidade e controle do nome lógico da operação.
- Cloud export `false` padrão; aprovação explícita + escopo, region/retention/contrato, redigido e registrado. Perfil `local` com `cloud-fallback: false` deve falhar controladamente se indisponível.
- IA não tem consulta SQL livre nem repositório inteiro por default. Acesso para Guardian passa por tools de leitura com auth escopada.

```yaml
pearfy:
  metric:
    privacy:
      mode: strict
      capture-request-bodies: false
      capture-response-bodies: false
      capture-sql-parameters: false
      export-raw-traces: false
      minimum-sample-size: 30
    ai:
      enabled: true
      profile: metrics-diagnostics
      export: aggregates-only
      cloud-export-approved: false
```

**30 é valor ilustrativo, não limiar de anonimato garantido.** Todos providers/modelos são configurados em `pearfy.ai` (doc 02). Compartilhar componentes de privacy com CRMInsights só quando políticas e domínios forem corretamente isolados.

## Gate

Canary PII/secret em corpo, parâmetros, erro externo e nome de rota dinâmica; testar local/cloud e payload exportado; small cohorts suprimidas; proxy cloud bloqueado mesmo se endpoint local for redirecionado sem permissão; no fallback implícito; o relatório indica data quality e lacunas.

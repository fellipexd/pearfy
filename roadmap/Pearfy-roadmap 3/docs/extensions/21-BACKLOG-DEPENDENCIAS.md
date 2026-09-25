# 21 — Backlog priorizado por dependências (roadmap v1.4)

Prioridade descreve a sequência de **construção proposta**; não afirma estágio atual da branch. Respeitar recursos já implementados e testes atuais, não duplicar.

| Marco | Entregas | Depende de | Gate |
|---|---|---|---|
| E0 | Inventory do repo + baseline + capability graph | v1.3 | ADR/diff e testes baseline |
| E1 | Module Manager CLI, manifest, graph, add/list/doctor/remove seguro | SwiftPM/CLI | mínimos/reinstall/cycles/lock |
| E2 | PearfyLogs core, privacy, stdout, correlação | Core/Obs se presente | canary secrets/offline/overhead |
| E3 | OTLP/presets Grafana Loki/Datadog + adapters outros | E2 | smoke tests e configs |
| E4 | PearfyWebhooks + PearfyJobs + inbox/outbox | Data/Transactions | 3 réplicas/fault injection |
| E5 | PearfyAI central + primeiro adapter | E1/Security | profile, no cloud fallback |
| E6 | PearfyMessaging + Telegram | E4 | signature/dup/lease |
| E7 | PearfyChatbot + tools, handoff | E5/E6 | tool ACL/concurrency |
| E8 | PearfyWhatsApp | E4/E6 contracts | API/policy/signatures |
| E9 | PearfyObservability refinements + PearfyMetric base | E2, telemetry | hist/cardinality/overhead |
| E10 | PearfyMetricAI + privacy export | E5/E9 | blocked PII/cloud opt-in |
| E11 | PearfyBackoffice RBAC/groups/tenant/audit | Security/Data/E1 | ACL/role inheritance |
| E12 | PearfyApprovals | E11/Transactions/Jobs | two-person/multi-instance |
| E13 | PearfyConnect SDK BKO + optional UI | E11/E12/Connect | SDK parity/backend ACL |
| E14 | PearfyCRM | E11/Data | tenant/timeline/tasks |
| E15 | CRMInsights + privacy + central AI profile | E5/E14 | no provider-in-module |
| E16 | Notifications, Storage, Identity, Realtime, Integrations | E1/E4 as needed | provider certification |
| E17 | Blueprints, end-to-end scenarios | módulos selecionados | plan/dry-run/rollback |

## Entrega incremental

Não trabalhar E1–E17 simultaneamente. Para cada módulo: minimal public contracts → implementation → unit tests → DB/adapter tests → integration tests → docs/examples → CLI scaffold → Guardian quality gates → benchmark; somente então marcar pronto. Runtime Swift 6 concurrency e DB adapter capabilities devem ser respeitados.

## Dependências não óbvias

- Approval necessita estado durável e ledger/audit, mas não necessariamente Payments.
- WhatsApp/Telegram utilizam Messaging e Webhooks/Jobs, mas não precisam de AI/Chatbot.
- CRMInsights necessita CRM e PearfyAI, mas provider local/cloud não é escolhido no CLI CRM.
- MetricAI necessita Metric + PearfyAI, não acesso a raw Log Store.
- Logs pode rodar com stdout JSON sem OTLP/Grafana/Datadog.
- AI provider cloud deve ser instalado apenas se ambiente aprovar políticas e credenciais.

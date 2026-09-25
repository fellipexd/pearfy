# 19 — Pearfy Blueprints: composição de módulos

Blueprint é RECEITA versionada do Module Manager; **não cria framework paralelo** nem injeta domínios no Core. `pearfy blueprint add <name> --dry-run` exibe árvore, migrations, APIs e providers faltantes antes de aplicar. Reexecução idempotente.

| Blueprint | Módulos mínimos | Opcionais |
|---|---|---|
| customer-support | Chatbot, Messaging, Jobs/Webhooks | WhatsApp, Telegram, AI provider, CRM |
| bko-crm | Backoffice, Approvals, CRM, Connect BKO | UI React, CRMInsights, notificações |
| saas | Identity, MultiTenant, Jobs, Audit | Subscriptions, FeatureFlags |
| marketplace | Identity, Orders app template, Jobs | Payments, Messaging, Notifications |
| realtime-game | Realtime, Connect WS, Observability | Presence adapter, Redis |
| iot-control | Messaging/Events, Jobs, Audit | Channels, secure device contracts |
| media-platform | Storage, Jobs | Search, CDN provider |

```bash
pearfy blueprint add customer-support --dry-run
pearfy blueprint add bko-crm
pearfy blueprint inspect bko-crm
```

Blueprint não configura automaticamente credencial externa real ou ativa provider cloud; guided setup com validação central do PearfyAI. `remove blueprint` não drop dados e só remove módulo não requerido pelo restante do app; output mostra decisões.

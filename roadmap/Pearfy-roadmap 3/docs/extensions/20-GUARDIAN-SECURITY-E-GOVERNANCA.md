# 20 — Guardian: qualidade transversal e enforcement

MCP/AGENTS.md orientam agentes; gates do CLI/CI/computação real de testes decidem. Falta de tool/teste obrigatório -> INCOMPLETE/FAIL; nunca relatório inventado. Revisar estado real do repo antes de aplicar roadmaps.

## Regras novas obrigatórias

- **Module Manager:** não trazer dependências especializadas involuntárias; validar provenance, lock, ciclos, setup idempotente e rollback não destrutivo.
- **AI:** provider/profile/segredos SOMENTE na config central de PearfyAI. Módulos consumidores usam profile autorizado; local não faz fallback cloud silencioso.
- **Webhooks/messaging/jobs:** verificar origem, inbox/outbox, dedup, scope por tenant+account, retry seguro, lease/fencing, resultados incertos e 3 instâncias.
- **Backoffice:** ACL de servidor com contexto recurso/tenant; herança sem ciclo/escalada; revogação; requester e aprovadores distintos, payload vinculado à decisão, permissão revalidada, claim de execução único.
- **CRM:** sem acesso cross-tenant, PII minimizada, connector opt-in, AI sem acesso irrestrito a customer record.
- **Logs:** secret/PII não entra no exporter; código não loga Input inteiro; redaction antes de stdout/OTLP/cloud; logs != audit.
- **Metric:** histogramas agregados de forma válida; route templates/low cardinality; sem query params/raw traces na IA; cloud opt-in.
- **Integrations:** mocks/contract tests, SSRF e API schema untrusted, auth/timeout/retry com semântica real, no auto-retry de efeito não idempotente.
- **Connect:** `@RouteGroup` exporta SDK, não autoriza; BKO TS only pela policy; collections Postman por grupo e cURL REST individual.

## Gates por mudança

| Mudança | Verificações mínimas |
|---|---|
| Nova role ou herança | cycle/tenant/scope/security test |
| Nova política de aprovação | requester exclusion, distinct actors, replay/concurrency, audit |
| CRMInsights | payload privacy diff, AI profile central, cloud egress deny test |
| Novo sink de logs | secret canary, export/offline, bounded queue, duplicate metadata |
| Nova query instrumentada | normalização, no binds, cardinality, no N+1 oculto |
| Novo connector/chatbot | signature, idempotency, external failure, provider constraints |

Não “consertar” risco de segurança apenas com comentário ou botão desabilitado na UI. Nenhuma alteração autônoma do Guardian deve entrar em produção sem gates e review definidos pelo projeto.

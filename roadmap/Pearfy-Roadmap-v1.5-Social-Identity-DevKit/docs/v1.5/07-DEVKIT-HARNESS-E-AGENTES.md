# Pearfy DevKit — harness de engenharia para projetos Pearfy

O harness é opcional e opera sobre o workspace explicitamente selecionado pelo usuário.

## Distinção

`PearfyAI` serve execução da aplicação (chatbot, CRMInsights, MetricAI) e centraliza providers/segredos/modelos/perfis; `PearfyDevKit` serve **desenvolvimento** (agentes, Skills, MCP). Não instalar runtime AI em apps sem demanda apenas por usar DevKit.

## Agents como papéis adaptáveis a cliente

- `pearfy-architect`: inventário, decisões e dependências, owner de roadmap.
- `pearfy-builder`: código de domínio, controllers/services com APIs reais.
- `pearfy-data`: schema, migration, ORM, transações e concorrência.
- `pearfy-integrator`: APIs externas, webhooks, jobs, inbox/outbox, auth.
- `pearfy-security`: identity/social-login, RBAC, approvals, privacy.
- `pearfy-connect`: contratos, SDK por grupo, Postman e cURL.
- `pearfy-qa`: testes, regressão, concurrency/fault injection.
- `pearfy-performance`: logs, traces, metrics e benchmarks.
- `pearfy-guardian`: reviewer independente e evidência de quality gates.

Orquestração no cliente compatível; não pressupor 9 processos LLM simultâneos. Os papéis consultam Skills do módulo/versão efetiva e receitas cross-module; não têm autoridade para atestar gate sem execução real.

## CLI proposto

```bash
pearfy ai init --client opencode
pearfy ai sync
pearfy ai inspect
pearfy ai doctor
pearfy new my-api --ai
```

`AGENTS.md`, `.agents/skills`, `.pearfy/harness` e adapters de cliente gerados sem sobrescrever regras específicas existentes. `ai sync` injeta APENAS skills relevantes à versão resolvida, atualiza links/referências atômicas e identifica conflitos locais.

## Lifecycle

Inspect → Plan/Diff → Approval (quando write/destructive) → Apply → Compile/Test/Contract/Guardian → Report com status PASS/FAIL/INCOMPLETE e evidências. Sandbox para scripts de Skills; desabilitar execução remota irrestrita e exportação de dados privados sem permissão.

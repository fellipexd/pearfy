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

## CLI Skills-first atual

```bash
pearfy ai init
pearfy ai init --client opencode
pearfy ai sync
pearfy ai inspect
pearfy ai doctor
pearfy ai mcp list
pearfy ai mcp enable populate
```

O checkout implementa o catálogo/fluxo em `docs/AI-SKILLS-FIRST.md`. `.agents/skills` e `.agents/agents` são canônicos; OpenCode usa links `.opencode/skills` e `.opencode/agents`. `ai sync` seleciona apenas Skills de módulos instalados, verifica versões/hashes e preserva mudanças locais. Project MCP é desabilitado inicialmente e concede tools apenas por módulo instalado/explicitamente habilitado. Configuração global de OpenCode não é editada.

Skills devem ficar compactas; detalhes entram em `references/`. O module registry versionado é factual: APIs ausentes/planned não se tornam implementadas por existir uma recipe ou documento neste roadmap.

## Lifecycle

Inspect → Plan/Diff → Approval (quando write/destructive) → Apply → Compile/Test/Contract/Guardian → Report com status PASS/FAIL/INCOMPLETE e evidências. Sandbox para scripts de Skills; desabilitar execução remota irrestrita e exportação de dados privados sem permissão.

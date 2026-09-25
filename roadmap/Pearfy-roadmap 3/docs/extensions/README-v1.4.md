# Pearfy — extensões e ferramentas operacionais | Roadmap v1.4

> **Planejamento de implementação, não release de software.** As APIs Swift, nomes de produtos, macros, opções CLI e configurações nos documentos são propostas e devem ser reconciliadas com o código real do repositório antes de implementá-las. Nenhuma feature é declarada pronta por existir neste ZIP.

Este complemento foi elaborado sobre o roadmap consolidado **v1.3 Connect** e registra as decisões posteriores: módulos opcionais por SwiftPM/CLI; integração central de IA no backend; chatbots e canais WhatsApp/Telegram independentes; facilitadores de webhooks/jobs/integrations/notifications/storage/identity/realtime; Backoffice BKO com RBAC, grupos, herança, aprovação por uma ou duas outras pessoas, CRM e insights; PearfyLogs, PearfyObservability e PearfyMetric com análise de IA e privacidade.

## Comece por aqui

1. `docs/extensions/00-VISAO-GERAL-E-DECISOES.md` — regras consolidadas e limite de cada módulo.
2. `docs/extensions/01-MODULE-MANAGER-CLI.md` — instalação modular efetiva, versões e uninstall.
3. `docs/extensions/02-PEARFY-AI-CENTRAL.md` — **única camada que configura provedores/modelos de IA**.
4. `docs/extensions/13-BACKOFFICE-RBAC-GRUPOS.md` e `14-APPROVALS-MAKER-CHECKER.md` — segurança administrativa.
5. `docs/extensions/09-LOGS-E-EXPORTADORES.md`, `10-OBSERVABILITY.md`, `11-METRIC-E-ANALISE.md` — telemetria.
6. `docs/extensions/21-BACKLOG-DEPENDENCIAS.md` e `22-TESTES-E-ACEITE.md` — ordem e gates.
7. `docs/integration/PROMPT-PARA-AGENTE.md` — prompt operacional para atualizar o projeto real.

## Regra de precedência

- Implementação e testes vigentes do projeto são a fonte da verdade sobre o que existe.
- Este v1.4 complementa e, **somente nos pontos de decisão nova explicitamente marcados**, refina o roadmap v1.3.
- Os roadmaps anteriores preservados no ZIP consolidado continuam referências históricas, não convite para reinstalar protótipos.
- Documentos técnicos podem fazer comparações com outros frameworks; código, identificadores e nomes específicos do Pearfy não devem conter marcas externas.

## Arquivos de entrega

- `Pearfy_Extensions_Roadmap_v1_4.zip`: só estes `.md` novos; indicado para entregar ao agente como adendo.
- `Pearfy_Roadmap_Consolidado_v1_4_Extensions.zip`: roadmap v1.3 preservado + estes documentos sob `Pearfy-roadmap/docs/extensions/`, com referência em `AGENTS.md` e `README.md`.

## Linha de produto

Core mínimo; infraestrutura genérica opcional; módulos de domínio opt-in; adaptadores de provedores opt-in; blueprints = composição explícita e reversível. API multi-instância: todas as réplicas acessam o banco transacional compartilhado; nenhuma primária gRPC obrigatória. SDK gerado por `@RouteGroup` é conveniência, nunca autorização no servidor.

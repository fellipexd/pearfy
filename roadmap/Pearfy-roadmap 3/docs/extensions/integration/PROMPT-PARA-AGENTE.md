# Prompt único para agente OpenCode — Pearfy Extensions v1.4

Você é o agente responsável por implementar **incrementalmente** o adendo `docs/extensions/` no repositório REAL do Pearfy.

**Não presuma que exemplos Swift, macros, CLI, nomes de módulos ou pastas apresentados nos `.md` existam na branch.** Faça inventário do código e dos testes antes de tocar em qualquer implementação. Este ZIP é um roadmap e não executa mudanças no projeto automaticamente.

## Primeiro passo obrigatório

1. Ler `AGENTS.md`, `docs/extensions/00-VISAO-GERAL-E-DECISOES.md`, `01-MODULE-MANAGER-CLI.md`, `02-PEARFY-AI-CENTRAL.md`, `20-GUARDIAN-SECURITY-E-GOVERNANCA.md`, `21-BACKLOG-DEPENDENCIAS.md` e `22-TESTES-E-CRITERIOS-DE-ACEITE.md`.
2. Reconciliar decisões com `docs/connect/` v1.3 e `docs/data/`, `docs/payments/`, `docs/distributed/` existentes; documentar divergências e ADRs.
3. Inventariar SwiftPM targets, DI, CLI, migrations, providers, tools MCP, security, atual logging/OTel, scaffolding e benchmarks. Não substituir código mais recente por starter histórico.
4. Propor **um marco E0–E17 por vez**, arquivos a alterar, produto SwiftPM, migrations, endpoints, testes, dependências e riscos; executar dentro do escopo aprovado pelo usuário/repo.
5. Implementar compilar/testar, executar testes de falha e segurança, checar contrato BKO, registrar cobertura e limites. Não declarar PASS por possuir um arquivo de teste que não rodou.

## Guardrails vinculantes

- Pearfy Core mínimo; módulos especialistas + adaptadores via `pearfy add`. CRM não instala Payments/WhatsApp/Chatbot automaticamente; WhatsApp só notificação possível sem IA.
- IA: provider/model/credentials/policy **exclusivamente PearfyAI no backend**. `pearfy add crm-insights` é correto; NÃO usar `--ai ollama` como config per module. Local-to-cloud fallback proibido sem policy explícita.
- API multi-instância: todas réplicas acessam mesmo datastore diretamente, sem primária gRPC; locks/idempotência/leases no banco compartilhado, com fencing e unknown outcomes.
- BKO: authz server-side por actor/action/resource/tenant; herança role acíclica; grupos/escopos independentes; aprovação 1/2 outros usuários distintos; hash canônico da operação; revalidar auth na aprovação e execução; idempotência de execução/audit.
- Logs: compatível swift-log, JSON stdout + OTLP; exporters por preset sem vendor SDK obrigatório; LGPD/privacy allowlist antes de egress; log operacional != audit durável; não prometer que todo destino está certificado.
- Metric: rota template/query normalizada, avg/p50/p95/p99, rollback/lock wait apenas quando instrumentado, histogramas corretos entre instâncias; IA recebe agregado aprovado sem raw PII/SQL/prompts e com hipótese vs evidência.
- Connect v1.3: `/bko` TS SDK, `/app` iOS+Android; collections Postman por grupo e cURL por rota; não usar export SDK como ACL.
- Swift 6 strict concurrency; sem esconder falhas ou introduzir dependências, runtime scheduler, formatos criptográficos próprios ou APIs fictícias.
- Apenas docs `.md` podem mencionar outros frameworks na comparação; source/imports/nomes Pearfy coerentes.

## Resultado esperado por marco

- Plano/ADR; diff revisável; produtos SwiftPM claros; migration SQL versionada (se houver); API pública e configuração; diagramas de dependência; testes unit/e2e/fault/security; script CLI help; benchmarks/offline mode; documentação atualizada com **status real**.
- Relatório: passou/falhou/não executado, motivo da omissão, limites do provider/driver, impacto em memória CPU e latência.
- Não iniciar todos os módulos em paralelo sem base Module Manager e test infrastructure.

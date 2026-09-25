# Pearfy — instruções de engenharia para agentes

Ler antes de editar: `docs/09-ROADMAP-ATUALIZADO.md`, `docs/decisions/01-ARQUITETURA-E-NOMES.md`, `docs/data/`, `docs/distributed/`, `docs/payments/`, `docs/ai/` e `docs/integration/` conforme escopo da tarefa. Fonte factual de implementações: código/testes vigentes, não exemplos de documentação ou protótipo histórico do pacote.

## Regras mandatórias
- Contratos Swift tipados, legíveis, com mínimo de código duplicado. Reutilizar o que existe.
- `@Autowired`/DI resolvido na construção, sem service locator por request; usar APIs **realmente disponíveis** na branch.
- UUIDv7 padrão para ID UUID; outras estratégias somente com tipo válido e contrato explícito.
- Modelos Swift como schema desejado; migration SQL gerada, versionada, revisável e com aprovação para destruição.
- `@Transaction`/equivalente só após garantir tx física única e semântica real de commit/rollback; não fingir atomicidade entre bancos independentes.
- `PearfyTransactionalStore` genérico; `PaymentEngine` domínio financeiro. Driver concreto só no adapter.
- Mesma API multi-instância -> acesso direto ao mesmo banco transacional lógico por réplica; nenhuma instância principal gRPC.
- Lock e idempotência duráveis no armazenamento; mutex/semaforo/fila não substituem integridade.
- Operações financeiras: autorização, dinheiro exato, idempotência escopada, ledger equilibrado, recuperação de commit unknown, retries seguros e outbox.
- MCP orienta, CLI/CI impõem; falha de verificação obrigatória -> INCOMPLETE/FAIL, nunca PASS.
- Arquitetura de aplicação pode ser configurada; default Modular Clean Architecture sem boilerplate artificial.
- Imports, nomes de módulos, símbolos, scripts e comentários de código só utilizam nomenclatura Pearfy/neutra; comparações externas apenas em `.md`.

## Antes de concluir
Executar testes pertinentes; documentar ambiente e revisão; verificar mudanças de contratos, performance, segurança, SQL e concorrência; não afirmar suporte a banco ainda não certificado nem resultado de teste não executado. Não reescrever funcionalidades em andamento apenas para seguir exemplos deste documento.

## Pearfy Connect v1.3 (quando modificar routes/client/API/contracts)
- Ler `docs/connect/00-LEIA-ME-ROADMAP.md`, `02-ROUTE-GROUPS-E-POLITICAS.md`, `05-SECURE-PAYLOAD-E-CHAVES.md` e `08-GUARDIAN-E-COMPATIBILIDADE.md` antes de alterar grupos, endpoints, transportes ou SDKs.
- `@RouteGroup` define exportação, não autorização. `/bko` -> TS; `/app` -> Swift iOS + Kotlin Android; `/public` -> três; sem grupo não exporta. Endpoint só pode **restringir** targets do grupo sem aprovação explícita de alteração da policy.
- Contract IR como fonte única de SDKs, OpenAPI/AsyncAPI/Protobuf, `.pearfy`, collection Postman POR GRUPO e cURL INDIVIDUAL por endpoint HTTP. Compatibilidade com versões mobile já publicadas é parte do gate.
- TLS obrigatório em produção. Payload criptografado adicional, quando exigido, nunca sofre downgrade; protocolo auditável, chaves do servidor fora do cliente e antirreplay multi-instância. SDK não é barreira de segurança.
- Não presumir gRPC nativo no browser, WSS como entrega garantida, ou Postman collection HTTP como embalagem universal de todos os protocolos.
- Código histórico neste ZIP não pode substituir a implementação mais nova do usuário.


## Extensões modulares v1.4 (quando tocar em IA, comunicação, BKO, CRM, Logs ou Metric)
- Ler `docs/extensions/README-v1.4.md`, `00-VISAO-GERAL-E-DECISOES.md`, `01-MODULE-MANAGER-CLI.md`, `02-PEARFY-AI-CENTRAL.md`, `20-GUARDIAN-SECURITY-E-GOVERNANCA.md`, `21-BACKLOG-DEPENDENCIAS.md` e documento do módulo alterado.
- Módulos especializados são opt-in via CLI/SwiftPM. `pearfy add crm-insights` **não** escolhe provider de IA; providers/modelos/segredos e fallback são configurados exclusivamente na camada backend `PearfyAI`.
- BKO: roles, grupos e scope são eixos distintos; controle server-side; requester e 1/2 aprovadores distintos; autorização validada no pedido, na decisão e na execução, com audit/idempotência durável.
- PearfyLogs exporta eventos sanitizados a stdout/OTLP; logs operacionais NÃO substituem audit. PearfyMetric analisa agregados, não envia raw traces/PII à IA cloud.
- Preserve arquitetura multi-instância Opção A (DB compartilhado por réplica, sem gRPC primary), legado v1.3 Connect (SDKs por grupo) e implementação atual da branch.

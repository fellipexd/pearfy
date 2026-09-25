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

# Backlog complementar — executar sem refazer o Pearfy existente

IDs abaixo são novas issues propostas; não marcar concluídas sem checar a branch atual e evidência de testes.

| ID | Prioridade | Dependências | Entrega |
|---|---|---|---|
| PAD-001 | P0 | inventário | mapear Swift toolchain, modules, migrations, tests e API real da branch |
| PAD-002 | P0 | macros/discovery atuais | contrato `SchemaIR` versionado, entidades e IDs UUIDv7 default |
| PAD-003 | P0 | PAD-002 | PostgreSQL schema diff -> SQL versionado revisável, checksum/drift |
| PAD-004 | P0 | PAD-003 | locking de runner e deploy de migrations sob réplicas |
| PAD-005 | P0 | adapter SQL | `TransactionalStore` com transação física única e pool |
| PAD-006 | P0 | PAD-005 | `@Transaction` / closure, commit/rollback, errors, cancellation |
| PAD-007 | P0 | PAD-005 | locking/canonical order, conditional writes, retry seguro por driver |
| PAD-008 | P0 | PAD-005, PAD-006 | ORM CRUD/query builder tipado, binding, paging |
| PAD-009 | P0 | PAD-005-PAD-008 | testes multi-processo e falhas de conexão/commit |
| PAD-010 | P1 | PAD-007, PAD-009 | drivers adicionais certificados caso a caso |
| PAY-001 | P1 | PAD-006-PAD-009 | Money exato + PaymentEngine contract + authz |
| PAY-002 | P1 | PAY-001 | idempotência durável e escopada + fingerprint |
| PAY-003 | P1 | PAY-002 | transferências atômicas com locking e constraints |
| PAY-004 | P1 | PAY-003 | ledger duplo, reservas/reversões e reconciliação |
| PAY-005 | P1 | PAY-004 | outbox/inbox e orquestrador de pagamentos externos |
| PAI-001 | P0 | inventário | regras Guardian na CLI/build/CI; evidência por revisão |
| PAI-002 | P1 | contratos/discovery | MCP de leitura de arquitetura, schema e contratos |
| PAI-003 | P1 | PAI-001 | security/query/transactions/migrations Guardian policies |
| PAI-004 | P1 | macros + MCP SDK | MCP tools/resources/prompts typed com authz servidor |
| PNET-001 | P2 | DI, transport | gRPC/Protobuf para microsserviços distintos, não coordenação entre réplicas |

## Slices recomendadas
A. Inventário atual -> schema IR -> migrations PostgreSQL -> transações reais -> locking -> multi-instância.
B. Paralelo: Guardian CLI com regras verificáveis de DI, SQL, migrations e quality; MCP vem como adaptador, não como substituto de CI.
C. PaymentEngine após capacidades financeiras do store certificadas.
D. Adapters adicionais com testes reais; não bloquear MVP inteiro esperando todos os bancos.

## Definition of Done por issue
- Código real compila em release/debug quando apropriado; strict concurrency ativo.
- Testes unitários e de integração relevantes rodaram em ambiente documentado.
- Sem API inventada; exemplos marcados como alvo até implementação.
- Contratos/documentação atualizados; perf baseline para hot path.
- Guardian report não usa “aprovado” quando teste/verificador obrigatório esteve indisponível.

# Pearfy — roadmap consolidado e incremental (adendo 2026-09)

> STATUS: planejamento. Este pacote inclui uma fotografia do protótipo original e os documentos posteriores. **Não afirma refletir o código mais recente do usuário** nem altera a implementação em curso. Toda API de exemplo ainda não implementada está sinalizada como contrato-alvo.

## Objetivo
Incorporar decisões posteriores ao roadmap inicial: arquitetura configurável com padrão Modular Clean Architecture; ORM e migrations model-first; UUIDv7 padrão e alternativas tipadas; @Transaction; armazenamento transacional independente de banco; acesso direto ao banco por múltiplas réplicas da MESMA API; PaymentEngine opcional; contratos gRPC/MCP; Guardian obrigatório para implementações com LLM.

## Fonte de verdade e precedência
1. Código e testes **atualmente implementados** no repositório do usuário determinam o estado factual da execução.
2. Estas ADRs registram as **decisões de produto** e prevalecem, onde houver divergência, sobre documentos de planejamento anteriores.
3. O roadmap inicial e o adendo de performance continuam válidos nos pontos que não conflitam.
4. Exemplos nesta documentação são APIs desejadas, não prova de implementação.
5. Não trocar módulos prontos por placeholders ou stubs para encaixar a documentação.

## Trilha de implementação, sem reiniciar a fase 1
| Marco | Dependências | Entrega verificável |
|---|---|---|
| G0 Inventário | repositório atual | matriz: pronto/parcial/ausente; testes e contratos existentes preservados |
| G1 Contratos + DI | Core, macros, discovery | injeção sem resolve por request e contratos públicos tipados |
| G2 Schema Compiler | macros, discovery | @Entity/@ID/@Column -> representação determinística do schema |
| G3 Migrate | compiler, adapter SQL inicial | diff, SQL revisável, checksum, drift, lock de migração |
| G4 Transactions | banco real, pool, context | @Transaction e withTransaction; rollback/commit; propagação e cancelamento |
| G5 ORM | schema + transactions | CRUD, query builder tipado, paginação, bulk e prepared queries |
| G6 Concurrency | transaction manager, adapters | locks ordenados, optimistic/conditional writes, retry seguro por driver |
| G7 Multi-instance | G4-G6 | múltiplos processos no mesmo banco, idempotência compartilhada |
| G8 Payments (opcional) | G4-G7, security | transferência atômica, ledger, reserva e reversão idempotente |
| G9 Guardian | cada marco, desde G0 | regras automatizadas e CI fail-closed; MCP como interface auxiliar |
| G10 gRPC/MCP | contratos, DI, security | transporte entre serviços distintos e ferramentas tipadas |
| G11 Release | todos os gates aplicáveis | matriz de bancos certificados, documentação, benchmarks e fault tests |

G9 é transversal: não aguardar finalização do ORM para iniciar as políticas mais simples do Guardian. Drivers posteriores só recebem selo compatível após executar a mesma suíte de conformidade.

## Arquivos acrescentados
- `docs/decisions/`: ADRs e organização arquitetural.
- `docs/data/`: IDs, schema compiler, migrations, ORM, @Transaction, locking e adaptadores.
- `docs/distributed/`: consistência com múltiplas réplicas, operações entre bancos, gRPC.
- `docs/payments/`: motor financeiro e integridade contábil.
- `docs/ai/`: contratos, MCP e Guardian.
- `docs/integration/`: backlog, matriz de testes e instruções para agente.
- `performance-addendum/`: adendo v1.1 preservado integralmente.

## Regras inegociáveis
- DB-agnostic no contrato, adaptadores específicos e certificação de semântica; não alegar suporte indiscriminado.
- Sem transação distribuída automática entre bancos independentes.
- Sem servidor coordenador gRPC entre réplicas da mesma API.
- Nenhum lock em memória, fila ou Redis usado como única garantia de integridade.
- NUNCA fazer migrations destrutivas automaticamente em produção.
- A revisão aprovada vale apenas para o conteúdo exato do código analisado.
- A documentação pode comparar com outros frameworks; arquivos de código não carregam marcas externas.

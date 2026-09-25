# ADR-PFY-001 — arquitetura configurável e nomenclatura neutra

**Estado:** decisão de produto. **Default:** Modular Clean Architecture, agrupada por feature. **Obrigatoriedade:** nenhuma arquitetura é imposta a aplicações que usem Pearfy.

## Presets de projeto
`clean` (default), `hexagonal`, `layered`, `vertical-slice`, `mvc`, `minimal`, `custom`. DI, migrations, security, transactions, MCP e gRPC devem funcionar em qualquer preset; regras do Guardian respeitam o preset efetivamente configurado. O núcleo do framework obedece separação de contratos e adaptadores, independentemente do preset escolhido na aplicação.

## Camadas sugeridas no default
- Domain: Swift puro; entidades de domínio e invariantes, sem ORM/transport.
- Application: casos de uso, serviços, contratos e fronteiras transacionais.
- Infrastructure: ORM, entidades persistentes quando necessário, provedores externos e adaptadores de banco.
- Presentation: REST, gRPC e MCP.
- Organizar por feature (`Users/`, `Payments/`) e não pastas globais de controllers.
- Não exigir DTOs, protocolos e mapeadores separados quando não trazem benefício; o Guardian alerta contra camadas artificiais.

## Renomeação decidida
O nome genérico `PearfyFinancialStore` é substituído por **`PearfyTransactionalStore`**. Ele representa capacidades transacionais reutilizáveis por estoque, pagamentos, reservas e pedidos, sem regras financeiras no Core.

| Módulo | Fronteira |
|---|---|
| PearfyData | modelo, ORM e abstrações de persistência |
| PearfyTransactionalStore | operações transacionais tipadas e porta genérica |
| PearfyTransactionManager | ciclo BEGIN/COMMIT/ROLLBACK/propagation |
| PearfyConcurrency | estratégias de conflito e controle de capacidade |
| PearfyPostgres / PearfyMySQL / PearfySQLServer etc. | semântica de driver/banco específica |
| PearfyPayments | ledger, saldos, reservas e invariantes financeiros |
| PearfyGRPC | RPC entre serviços **distintos**, opcional |
| PearfyGuardian | diagnóstico e gates independentes da IA |

**Não** adicionar um Pearfy Coordinator central ou líder de API para serializar todas as gravações. Sem fallback automático `remote -> local` que burle ownership.

## Identificadores no código
Só Pearfy e nomes técnicos neutros; analogias com ecossistemas de terceiros permanecem em `.md`. Verificação de branding integra CI.

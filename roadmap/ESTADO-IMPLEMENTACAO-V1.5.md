# Estado de implementação — capacidades v1.5 do Pearfy

Atualizado em 2026-09-25 contra o código e os testes locais. O escopo é o Pearfy como framework independente: capabilities genéricas, opt-in e testáveis, sem dependência de uma aplicação consumidora específica.

## Matriz factual

| Capacidade | Estado | Evidência e lacunas |
|---|---|---|
| Arquitetura modular e Social Core | Parcial | `PearfySocial` define atores, handles validados, UUIDv7, visibilidade public/followers/private e contrato `SocialGraphStore`; `PearfyTransactions` adiciona unit-of-work genérica REQUIRED, rollback-only e erro tipado de commit unknown, adaptada ao PostgreSQL. Faltam profiles, actors coletivos/memberships e documentação/ergonomia opt-in completa. |
| Connect contracts | Parcial | Route Groups, operation metadata e request/response schema refs entram no IR; builtins e schemas construídos com refs são validados e incluídos transitivamente. `@ContractModel`/`@ContractField` geram descritores de DTOs Codable explicitamente marcados, agregados automaticamente pelo plugin do target, com suporte a campos escalares/opcionais e helpers de arrays. Faltam cobertura mais ampla de DTOs/Codable, contract diff e SDK generation. |
| Social Graph e privacidade | Primeiro slice implementado | `PearfySocialPostgres` oferece follows pending/accepted, approval, unfollow, block/unblock e `canView`, com ownership, constraints e transações. Faltam mute/friend/custom audiences, índices para leitura de conteúdo, concorrência multi-réplica e políticas de retenção. |
| Social Content, Feed e Media | Ausente | Sem posts, comentários, reações, armazenamento de mídia, feed/cursor, busca ou outbox de eventos sociais. |
| Moderação e comunidades | Ausente | Sem workflow de denúncia/revisão/appeal, membership, roles comunitários ou serviço genérico de notificações. |
| Identity e Social Login | Ausente | Sem contrato de identidade, OAuth/OIDC, associação opcional de credenciais ou testes de PKCE/state/nonce e concorrência de primeiro login. |
| Module Registry e Skills | Parcial | Module Manager cataloga produtos disponíveis, incluindo `PearfyTransactions`, e planeja mudanças SwiftPM gerenciadas. Faltam versões/capabilities verificáveis e Skills/recipes versionadas para projetos consumidores. |
| DevKit harness/agents | Ausente | Sem harness, execução isolada de tarefas, seleção de Skills ou relatório redigido. |
| MCP | Primeiro slice implementado | `pearfy mcp` oferece transporte local stdio, tools read-only para contexto do projeto e inventário/inspeção/plan de módulos, além de resources limitados ao workspace e registro. Ainda faltam code search, contracts/data/tests/integration tools, políticas de autorização e tools com consentimento de escrita. |
| Guardian | Ausente | Sem gates verificáveis de build/teste/segurança ligados ao registry, nem evidência reproduzível por capability. |
| Persistência e evolução de schema | Parcial | `SQLMigrationCatalog` carrega artifacts JSON versionados e parametrizados; `SQLMigrationRunner` valida IDs, grava SHA-256 de SQL/parâmetros, detecta drift, atualiza journal legado, serializa apply por advisory transaction lock PostgreSQL e expõe plan pending/applied/legacy/drift sem executar DDL de domínio. Ainda faltam detecção de migrations removidas/gaps, rollback plans e CLI; ver roadmap 2 G3. |

## Validação executada

- `bash scripts/test-integrations.sh --filter postgresSocialGraphEnforcesOwnerVisibilityFollowAndBlockPolicies`: 1 teste passou contra PostgreSQL local, incluindo ownership, aprovação, bloqueios, visibilidade e constraint de handle.
- `bash scripts/test-integrations.sh --filter postgresTransactionManagerCommitsAndRollsBackOnOnePhysicalTransaction`: 1 teste passou contra PostgreSQL local.
- `bash scripts/test-integrations.sh`: 101 testes passaram em Debug com PostgreSQL/Redis locais, incluindo discovery de schemas Connect via `@ContractModel` e MCP read-only.
- `bash scripts/test-integrations.sh -c release`: 101 testes passaram em Release com PostgreSQL/Redis locais, incluindo discovery de schemas Connect via `@ContractModel` e MCP read-only.
- `bash scripts/test-unit.sh`: 101 testes passaram em Debug, incluindo discovery de schemas Connect via `@ContractModel` e MCP read-only.

Esses resultados cobrem apenas as capacidades presentes neste checkout; não certificam capacidades marcadas como ausentes/parciais.

## Sequência independente

1. Completar G3 do roadmap 2: detecção de gaps/removals, rollback plans e CLI segura; catálogo versionado e API de plan já existem.
2. Completar Transaction Manager com isolamento contra uso paralelo de uma unit, propagation adicional e reconciliação/fault tests de commit unknown.
3. Evoluir Module Registry para versões/capabilities verificáveis e módulos opt-in.
4. Evoluir Social Graph e implementar Content/Moderation/Feed em slices com testes de privacy e concorrência.
5. Implementar Identity/Social Login, DevKit/Skills, MCP e Guardian com contratos e gates executáveis.

A v1.5 **não está completa**; capabilities ausentes continuam explicitamente fora do estado entregue.

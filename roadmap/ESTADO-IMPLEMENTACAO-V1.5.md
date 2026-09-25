# Estado de implementação — capacidades v1.5 do Pearfy

Atualizado em 2026-09-25 contra o código e os testes locais. O escopo é o Pearfy como framework independente: capabilities genéricas, opt-in e testáveis, sem dependência de uma aplicação consumidora específica.

## Matriz factual

| Capacidade | Estado | Evidência e lacunas |
|---|---|---|
| Arquitetura modular e Social Core | Parcial | `PearfySocial` define atores, handles validados, UUIDv7, visibilidade public/followers/private e contrato `SocialGraphStore`; `PearfyTransactions` adiciona unit-of-work genérica REQUIRED, rollback-only e erro tipado de commit unknown, adaptada ao PostgreSQL. Faltam profiles, actors coletivos/memberships e documentação/ergonomia opt-in completa. |
| Social Graph e privacidade | Primeiro slice implementado | `PearfySocialPostgres` oferece follows pending/accepted, approval, unfollow, block/unblock e `canView`, com ownership, constraints e transações. Faltam mute/friend/custom audiences, índices para leitura de conteúdo, concorrência multi-réplica e políticas de retenção. |
| Social Content, Feed e Media | Ausente | Sem posts, comentários, reações, armazenamento de mídia, feed/cursor, busca ou outbox de eventos sociais. |
| Moderação e comunidades | Ausente | Sem workflow de denúncia/revisão/appeal, membership, roles comunitários ou serviço genérico de notificações. |
| Identity e Social Login | Ausente | Sem contrato de identidade, OAuth/OIDC, associação opcional de credenciais ou testes de PKCE/state/nonce e concorrência de primeiro login. |
| Module Registry e Skills | Parcial | Module Manager cataloga produtos disponíveis, incluindo `PearfyTransactions`, e planeja mudanças SwiftPM gerenciadas. Faltam versões/capabilities verificáveis e Skills/recipes versionadas para projetos consumidores. |
| DevKit harness/agents | Ausente | Sem harness, execução isolada de tarefas, seleção de Skills ou relatório redigido. |
| MCP | Ausente | Sem servidor/tool registry MCP nem políticas read-only/write com escopo e testes de autorização. |
| Guardian | Ausente | Sem gates verificáveis de build/teste/segurança ligados ao registry, nem evidência reproduzível por capability. |
| Persistência e evolução de schema | Parcial | `SQLMigrationRunner` valida IDs, grava SHA-256 de SQL/parâmetros, detecta drift para migrations declaradas, atualiza journal legado, serializa apply por advisory transaction lock PostgreSQL e expõe plan com estados pending/applied/legacy/drift. O plan só cria/atualiza o journal, não executa DDL de domínio. Ainda faltam catálogo completo, detecção de migrations removidas/gaps, planos de rollback e CLI; ver roadmap 2 G3. |

## Validação executada

- `bash scripts/test-integrations.sh --filter postgresSocialGraphEnforcesOwnerVisibilityFollowAndBlockPolicies`: 1 teste passou contra PostgreSQL local, incluindo ownership, aprovação, bloqueios, visibilidade e constraint de handle.
- `bash scripts/test-integrations.sh --filter postgresTransactionManagerCommitsAndRollsBackOnOnePhysicalTransaction`: 1 teste passou contra PostgreSQL local.
- `bash scripts/test-integrations.sh`: 98 testes passaram em Debug com PostgreSQL/Redis locais.
- `bash scripts/test-integrations.sh -c release`: 98 testes passaram em Release com PostgreSQL/Redis locais.
- `bash scripts/test-unit.sh`: 98 testes passaram em Debug sem depender de serviços externos.

Esses resultados cobrem apenas as capacidades presentes neste checkout; não certificam capacidades marcadas como ausentes/parciais.

## Sequência independente

1. Completar G3 do roadmap 2: catálogo/artifacts de migrations, detecção de gaps/removals, rollback plans e CLI segura.
2. Completar Transaction Manager com isolamento contra uso paralelo de uma unit, propagation adicional e reconciliação/fault tests de commit unknown.
3. Evoluir Module Registry para versões/capabilities verificáveis e módulos opt-in.
4. Evoluir Social Graph e implementar Content/Moderation/Feed em slices com testes de privacy e concorrência.
5. Implementar Identity/Social Login, DevKit/Skills, MCP e Guardian com contratos e gates executáveis.

A v1.5 **não está completa**; capabilities ausentes continuam explicitamente fora do estado entregue.

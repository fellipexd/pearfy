# Estado de implementação — capacidades v1.5 do Pearfy

Atualizado em 2026-09-25 contra o código e os testes locais. O escopo é o Pearfy como framework independente: capabilities genéricas, opt-in e testáveis, sem dependência de uma aplicação consumidora específica.

## Matriz factual

| Capacidade | Estado | Evidência e lacunas |
|---|---|---|
| Arquitetura modular e Social Core | Parcial | `PearfySocial` define atores, handles validados, UUIDv7, visibilidade public/followers/private e contrato `SocialGraphStore`; `PearfyTransactions` adiciona unit-of-work genérica REQUIRED, rollback-only e erro tipado de commit unknown, adaptada ao PostgreSQL. Faltam profiles, actors coletivos/memberships e documentação/ergonomia opt-in completa. |
| Connect contracts | Parcial | Route Groups, operation metadata e request/response schema refs entram no IR; builtins e schemas construídos com refs são validados e incluídos transitivamente. `@ContractModel`/`@ContractField` geram descritores de DTOs Codable explicitamente marcados, agregados automaticamente pelo plugin do target, com suporte a campos escalares/opcionais e helpers de arrays. Faltam cobertura mais ampla de DTOs/Codable, contract diff e SDK generation. |
| Social Graph e privacidade | Primeiro slice implementado | `PearfySocialPostgres` oferece follows pending/accepted, approval, unfollow, block/unblock e `canView`, com ownership, constraints e transações. Faltam mute/friend/custom audiences, índices para leitura de conteúdo, concorrência multi-réplica e políticas de retenção. |
| Social Content e Feed | Parcial — contratos de domínio | `Sources/PearfySocial/SocialContent.swift` define post/comment drafts que preservam `ownerID`, estados/revisões de moderação, cursor de feed, reações, notificações com idempotency key e `SocialContentStore`. Validação unitária cobre IDs estáveis e limites. **Ainda não há implementação de store PostgreSQL**, queries/feed/privacy, persistência idempotente/outbox nem testes multi-réplica; o fluxo não é operacional. |
| Moderação | Parcial — worker genérico | `SocialModerationWorker` coordena claim → provider → complete/retry sem manter transação aberta durante provider. Erro de provider é guardado por tipo, sem mensagem sensível; falha de commit propaga e deixa o lease expirar. O protocolo não tem adapter durável, Guardian completo nem política central PearfyAI; não operar como worker de produção. |
| Comunidades, mídia e notifications runtime | Ausente / parcial | Tipos genéricos de notificação e contrato de leitura foram iniciados; sem persistência, entrega, outbox, delivery/read status, membership/roles de comunidade ou mídia. |
| Identity e Social Login | Ausente | Sem contrato de identidade, OAuth/OIDC, associação opcional de credenciais ou testes de PKCE/state/nonce e concorrência de primeiro login. |
| Module Registry e Skills | Primeiro slice Skills-first | Module Registry v2 cataloga módulos implementados/parciais/planejados, versões de workspace/SDK, products, capacidades, references, comandos, contracts, restrições e validação. `pearfy ai init/sync/inspect/doctor` instala Skills apenas para módulos selecionados; hashes/versiones detectam drift e preservam edições. O package ainda não publica releases SemVer por módulo. |
| DevKit harness/agents | Primeiro slice Skills-first | `.agents/skills` é canônico; OpenCode recebe symlinks locais para Skills e papéis compactos. `AGENTS.md` global do checkout permanece curto e `pearfy ai doctor` valida adapters/Registry sem substituir o Guardian. Não se exige execução simultânea de agentes. |
| MCP | Transporte seletivo | Tools/resources estáticos de project/modules foram movidos ao CLI/Registry/Skills. Por padrão tools Pearfy listados = 0; `pearfy ai mcp enable populate` libera somente Populate quando instalado. Populate MCP limita-se à inspeção/planejamento; escrita no banco e tokens de aprovação permanecem na CLI local. Não há MCP DevKit traces/metrics. |
| Guardian | Primeiro slice local | `pearfy guardian verify` roda `swift build` e `scripts/test-unit.sh`, exige Package.swift/Tests e verifica variáveis de serviço citadas pelos testes; exit code distingue PASS/FAIL/INCOMPLETE. Escopo limitado a build/test/env local; não verifica policy SQL/schema, segurança, paridade de contratos, release, logs/evidência assinada ou registry-capabilities. Não equivale ao Guardian v1.5 completo. |
| Persistência e evolução de schema | Parcial | `SQLMigrationCatalog` carrega artifacts JSON versionados e parametrizados; `SQLMigrationRunner` valida IDs, grava SHA-256 de SQL/parâmetros, detecta drift, atualiza journal legado, serializa apply por advisory transaction lock PostgreSQL e expõe plan pending/applied/legacy/drift sem executar DDL de domínio. Ainda faltam detecção de migrations removidas/gaps, rollback plans e CLI; ver roadmap 2 G3. |

## Validação executada

- `bash scripts/test-integrations.sh --filter postgresSocialGraphEnforcesOwnerVisibilityFollowAndBlockPolicies`: 1 teste passou contra PostgreSQL local, incluindo ownership, aprovação, bloqueios, visibilidade e constraint de handle.
- `bash scripts/test-integrations.sh --filter postgresTransactionManagerCommitsAndRollsBackOnOnePhysicalTransaction`: 1 teste passou contra PostgreSQL local.
- `bash scripts/test-integrations.sh`: 101 testes passaram em Debug com PostgreSQL/Redis locais, incluindo discovery de schemas Connect via `@ContractModel` e MCP read-only.
- `bash scripts/test-integrations.sh -c release`: 101 testes passaram em Release com PostgreSQL/Redis locais, incluindo discovery de schemas Connect via `@ContractModel` e MCP read-only.
- `bash scripts/test-unit.sh`: 101 testes passaram em Debug, incluindo discovery de schemas Connect via `@ContractModel` e MCP read-only.
- `bash scripts/test-unit.sh --filter 'GuardianCommand|SocialContent'`: 12 testes passaram após adicionar os contracts/worker e o slice CLI Guardian.
- `swift run pearfy guardian verify`: build passou, os 115 testes unitários passaram; status foi `INCOMPLETE` porque `PEARFY_TEST_POSTGRES_HOST` e `PEARFY_TEST_REDIS_HOST` não estavam configurados.

Esses resultados cobrem apenas as capacidades presentes neste checkout; não certificam capacidades marcadas como ausentes/parciais.

## Sequência independente

1. Implementar `SocialContentStore` PostgreSQL com migrations versionadas e atomicidade de conteúdo + fila/outbox; cobrir feed/blocks/visibility e notification idempotency em PostgreSQL real.
2. Testar dois clientes/processos concorrentes, lease recovery, digest/revision guard, retries e commit desconhecido; conectar política EmberGuard sem configurar IA no módulo Social.
3. Evoluir Guardian de build/test/env local para gates de SQL/migrations/contracts/security/registry com evidência reproduzível e status fail-closed.
4. Completar G3 de migration planning e a segurança concorrente do Transaction Manager antes de cortes de dados.
5. Evoluir Connect/Registry e só então ligar adapters consumidores; Identity/Social Login e comunidades seguem planejados. Skills-first/DevKit UI v1.7 tem primeiro slice em `docs/AI-SKILLS-FIRST.md` e `docs/PEARFY-DEVKIT-UI.md`.

A v1.5 **não está completa**; capabilities ausentes continuam explicitamente fora do estado entregue.

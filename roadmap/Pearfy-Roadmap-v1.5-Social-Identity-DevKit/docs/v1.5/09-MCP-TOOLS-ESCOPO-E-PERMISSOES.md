# PearfyMCP — leitura, ação estruturada e segurança

## Resources

`pearfy://project/context`, `/architecture`, `/modules`, `/contracts`, `/database`, `/routes`, `/status`; `pearfy://modules/{id}` sobre **versão instalada**. Dados privados e segredos não entram em resources de documentação.

## Tools propostas

`pearfy.project.inspect`, `pearfy.modules.list/inspect/plan/install`, `pearfy.code.search`, `pearfy.contracts.inspect/check`, `pearfy.data.inspect/migration.plan`, `pearfy.sdk.generate`, `pearfy.tests.run`, `pearfy.metric.inspect`, `pearfy.guardian.verify`, `pearfy.integration.plan`.

Cada tool: JSON Schema input/output, capability, escopo, limite tamanho, timeout, cancelamento e log de ação redigido. Falta de tool ≠ comando alucinado; propor alternativa ou marcar bloqueado. Preferir calls de CLI encapsuladas e allowlist a shell arbitrário.

## Permissões

READ repo/contract: limitado a workspace aprovado. WRITE repo, add deps, generate migration: consentimento/policy. SQL produção, prod deploy, secrets, env, cloud AI export: explicitamente restrito e/ou aprovação humana. Nunca `pearfy.migration.deploy` sem análise do diff, ambiente e autorização. MCP não substitui RBAC servidor ou qualidade em CI.

## Prompts versionados

`pearfy.create-project`, `add-feature`, `integrate-provider`, `plan-database-change`, `generate-sdk`, `review-security`, `investigate-regression`.

## Testes

Schema de tool inválido, path traversal, symlink escape, prompt injection em arquivos/docs e output provider, consumo de secrets, concurrent writes, autorização por workspace, false success quando comando falha. Registrar revisão/hash do código e gate executado.

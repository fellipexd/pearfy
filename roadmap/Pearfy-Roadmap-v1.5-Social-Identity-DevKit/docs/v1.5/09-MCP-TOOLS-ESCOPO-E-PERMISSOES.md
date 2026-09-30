# PearfyMCP — leitura, ação estruturada e segurança

> Este documento registra propostas históricas do roadmap v1.5. O checkout atual segue `docs/AI-SKILLS-FIRST.md`: documentação estática é Skill/CLI, não MCP. Nomes abaixo que não constem do Registry/servidor atual não são ferramentas utilizáveis.

## Resources

`pearfy://project/context`, `/architecture`, `/modules`, `/contracts`, `/database`, `/routes`, `/status`; `pearfy://modules/{id}` sobre **versão instalada**. Dados privados e segredos não entram em resources de documentação.

## Tools propostas

O servidor atual expõe **somente** ferramentas do module Registry para módulos instalados e explicitamente habilitados no `.pearfy/ai.json`. Hoje isso corresponde à família Populate; project/module catalog, plans, Guardian, Connect SDK, Metric e outras ferramentas citadas nesta proposta não estão expostos.

Cada tool: JSON Schema input/output, capability, escopo, limite tamanho, timeout, cancelamento e log de ação redigido. Falta de tool ≠ comando alucinado; propor alternativa ou marcar bloqueado. Preferir calls de CLI encapsuladas e allowlist a shell arbitrário.

## Permissões

READ repo/contract: limitado a workspace aprovado. WRITE repo, add deps, generate migration: consentimento/policy. SQL produção, prod deploy, secrets, env, cloud AI export: explicitamente restrito e/ou aprovação humana. Nunca `pearfy.migration.deploy` sem análise do diff, ambiente e autorização. MCP não substitui RBAC servidor ou qualidade em CI.

## Prompts versionados

`pearfy.create-project`, `add-feature`, `integrate-provider`, `plan-database-change`, `generate-sdk`, `review-security`, `investigate-regression`.

## Testes

Schema de tool inválido, path traversal, symlink escape, prompt injection em arquivos/docs e output provider, consumo de secrets, concurrent writes, autorização por workspace, false success quando comando falha. Registrar revisão/hash do código e gate executado.

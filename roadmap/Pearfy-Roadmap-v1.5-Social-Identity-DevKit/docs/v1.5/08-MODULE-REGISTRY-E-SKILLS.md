# Module Registry + Skills versionadas

## Registry é fonte factual

Registro `id`, package/product, versão efetiva SwiftPM, dependências, target Swift/OS, capabilities implemented vs planned, config, migrations, contrato/macros, public symbols, CLI workflows, schema docs, gate obrigatório e security/privacy policy. Estados `available`, `installed`, `configured`, `operational` verificáveis; documentação não basta para considerar operacional.

`pearfy modules inspect social` retorna versão + evidências e paths de fontes. Agentes não podem chamar `@SocialContentType` se não estiver na API dessa branch, mesmo que roadmap a cite.

## Skills

`SKILL.md` curto com frontmatter, quando usar, prerequisites, contratos reais, receita, erros comuns, testes e refs versionadas. Materiais longos ficam em `references/`; scripts versionados em `scripts/` e executados com autorização. Não colocar documento inteiro do framework no prompt; seleção por capability e tarefa.

Exemplo de layout:

```text
pearfy-skills/
  pearfy-social/SKILL.md
  pearfy-identity/SKILL.md
  pearfy-connect/SKILL.md
  pearfy-transactions/SKILL.md
  pearfy-devkit/SKILL.md
  pearfy-social/references/api-vX.md
```

## Integration Recipes

`social-with-identity`, `social-with-moderation`, `social-with-notifications`, `social-login-with-existing-user`, `payments-with-approvals`, `chatbot-with-crm`, `metric-with-guardian`, `logs-with-observability`, `application-social-domain-adapter`.

Cada recipe: preconditions, owner de escrita/dados, contracts/events, migrations, security, test matrix, rollback, privacy, version constraints. Evitar dependência circular entre Skills.

## Aceite

Projeto sem social não injeta social skill como obrigatória; versões incompatíveis resultam aviso/erro explícito; docs planejadas não viram símbolos afirmados implementados; atualização não apaga modificações manuais nem segredos.

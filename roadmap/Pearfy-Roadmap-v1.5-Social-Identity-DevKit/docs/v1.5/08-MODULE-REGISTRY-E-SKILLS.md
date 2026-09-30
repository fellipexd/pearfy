# Module Registry + Skills versionadas

## Registry é fonte factual

O checkout implementa Registry schema v2 em `Sources/PearfyCLIKit/module-registry.json`: `id`, nome, version/status, availability, requires/products, capacidades implementadas, Skill+version, references, CLI commands, source contracts, restrictions, validation gates e MCP tool names. `pearfy ai inspect` acrescenta o estado instalado/versão do projeto. `configured` e `operational` são `not-verified` até existir probe/runtime evidence; a ferramenta não deduz saúde operacional de um README.

`pearfy modules info <id>` retorna o estado de Registry; `pearfy ai inspect --module <id>` acrescenta installation/Skill state. Módulos planejados aparecem com `available:false`, sem product/Skill utilizável, e `pearfy add` os recusa. Agentes não podem chamar APIs somente documentadas no roadmap.

## Skills

As Skills implementadas do checkout ficam sob `.agents/skills/<skill>/SKILL.md`, com frontmatter e `pearfy-skill-version`; references ficam no mesmo diretório. A versão da Skill precisa coincidir com a versão catalogada. O objetivo de 300–800 tokens por corpo é uma meta; regras de segurança não são removidas para encurtar contexto. Scripts são versionados e executados com autorização. Não colocar documento inteiro do framework no prompt; selecionar por module/task.

Exemplo de layout:

Padrão atual: `AGENTS.md` curto → `pearfy ai inspect` → Skills só dos módulos selecionados → referências da integração aplicável. `pearfy ai sync` compara SHA-256 do último sync e não sobrescreve arquivos editados sem `--force`. `.opencode/skills` é uma camada de symlink, não uma cópia canônica divergente.

## Integration Recipes

`social-with-identity`, `social-with-moderation`, `social-with-notifications`, `social-login-with-existing-user`, `payments-with-approvals`, `chatbot-with-crm`, `metric-with-guardian`, `logs-with-observability`, `application-social-domain-adapter`.

Cada recipe: preconditions, owner de escrita/dados, contracts/events, migrations, security, test matrix, rollback, privacy, version constraints. Evitar dependência circular entre Skills.

## Aceite

Projeto sem social não injeta social skill como obrigatória; versões incompatíveis resultam aviso/erro explícito; docs planejadas não viram símbolos afirmados implementados; atualização não apaga modificações manuais nem segredos.

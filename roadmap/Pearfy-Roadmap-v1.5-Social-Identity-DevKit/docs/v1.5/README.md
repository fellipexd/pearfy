# Pearfy — incremento v1.5: Social, Identity e DevKit

**Natureza:** especificação e backlog; não prova que APIs exemplificadas já estão implementadas. **Idioma:** pt-BR. **Baseline:** roadmap consolidado v1.4. **Escopo:** capabilities independentes e opt-in do Pearfy.

## Guia de leitura

1. `docs/v1.5/00-DECISOES-E-ESCOPO.md` — arquitetura atual e limites.
2. `01`–`04` — arquitetura Social, grafo, conteúdo e moderação genéricos.
3. `06` — login social opcional, relacionamento com usuário existente.
4. `07`–`10` — Pearfy DevKit, Agents, Skills, MCP e Guardian.
5. `15`–`16` — backlog, testes e critérios de aceite das capabilities Pearfy.
6. `docs/v1.5/integration/PROMPT-IMPLEMENTAR-V1.5-PEARFY.md` — prompt de implementação do framework.

## Prioridade entre evidências

Código atual e testes do repositório > contratos efetivamente utilizados > roadmap versionado > snippets ilustrativos. Não inventar API Pearfy por constar no roadmap. Só marcar capability disponível quando estiver implementada e verificada neste checkout.

**Nomeação:** código do Pearfy usa nomes Pearfy/neutros. Nunca incluir tokens, segredos OAuth, dados pessoais reais ou dumps de produção no pacote.

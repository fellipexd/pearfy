# Pearfy Guardian — regras mandatórias para agentes LLM

## Invariante principal
A IA escreve; ferramentas independentes verificam. MCP orienta e expõe diagnóstico, CLI e CI aplicam as regras. Uma LLM não pode aprovar a própria alteração via afirmação textual. Aprovação é vinculada ao hash da revisão, versão das regras, ambiente e evidência de execução; nova alteração invalida a aprovação.

## Ciclo obrigatório
1. Inventariar repositório **atual** (não assumir que protótipo ZIP reflete branch do usuário).
2. Carregar decisões e preset arquitetural (default Modular Clean, outros permitidos).
3. Pesquisar componentes existentes; evitar repetição e abstração sem benefício.
4. Definir contratos, migrations, invariantes, falhas e testes ANTES de modificar.
5. Implementar sem alterar nome público ou comportamento estabilizado inadvertidamente.
6. Executar build, testes, security, DB checks, concurrency, quality; perf se alterar hot path.
7. Corrigir bloqueantes, rodar gate final e registrar limitações.

## Política de bloqueios
| Regra | Evidência / ação |
|---|---|
| PGR-001 | SQL dinâmico com dado não confiável -> bloquear; exigir binding |
| PGR-002 | Migration destrutiva sem revisão humana -> bloquear |
| PGR-003 | Escrita correlata sem atomicidade requerida -> bloquear |
| PGR-004 | Saldo fora do PaymentEngine -> bloquear |
| PGR-005 | Idempotência baseada só em memória/Redis para operação crítica -> bloquear |
| PGR-006 | Lock local como única garantia multi-instância -> bloquear |
| PGR-007 | gRPC coordenador único entre réplicas da mesma API -> violação arquitetural |
| PGR-008 | Repo depende de banco concreto dentro do domínio/motor genérico -> bloquear |
| PGR-009 | Float/Double em saldos ou movimentações -> bloquear |
| PGR-010 | Expor ferramenta MCP de escrita sem authz -> bloquear |
| PGR-011 | Secrets hardcoded / TLS desabilitado em prod -> bloquear |
| PGR-012 | Retry após commit unknown sem reconciliação -> bloquear |
| PGR-013 | Dependência nova duplicando módulo Pearfy -> review |
| PGR-014 | Teste concorrente ausente em motor financeiro alterado -> bloquear |
| PGR-015 | Compilar mas não executar testes obrigatórios -> INCOMPLETE |
| PGR-016 | Alias/DTO/mapper duplicado sem caso de uso -> review |
| PGR-017 | Mudar arquitetura do preset do usuário silenciosamente -> bloquear |
| PGR-018 | Afirmar suporte certificado a adapter não testado -> bloquear |

## Métricas e decisões humanas
Complexidade ciclomática, cognitiva, duplicação, tamanho e dependências são indicadores, não obsessão por menos linhas. Analisar diffs e apresentar provas/arquivos relacionados; limiares configuráveis. Migração destrutiva, risco financeiro e mudança pública incompatível precisam de revisão autorizada; a IA não pode concedê-la a si mesma.

## MCP tools previstas
`pearfy.context`, `pearfy.search`, `pearfy.contracts`, `pearfy.design`, `pearfy.security`, `pearfy.queries`, `pearfy.concurrency`, `pearfy.quality`, `pearfy.performance`, `pearfy.tests`, `pearfy.verify`.

## CI
Falha de analisador obrigatório -> INCOMPLETE (fail closed), não PASS. Proteger branch e releases com execução do gate por ambiente confiável; não aceitar apenas JSON gerado no workspace do agente. Não exigir feature futura como se fosse pronta: componente em desenvolvimento é testado por contrato e benchmark aplicável.

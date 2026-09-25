# Prompt para agente implementador — adendo incremental

Você está contribuindo no projeto Pearfy (framework backend Swift). Existe um roadmap principal **já em implementação**, acompanhado deste adendo de performance. Sua responsabilidade é incorporar as melhorias **sem reiniciar, renomear ou substituir** o código/roadmap existente.

## Instruções obrigatórias

1. Antes de editar, inspecione o branch atual, `Package.swift`, `Sources/`, `Tests/`, docs e backlog. Não assuma que o protótipo de DI descrito no roadmap está idêntico ao código vigente.
2. Gere um mapeamento entre os IDs `PPERF-*` e os IDs já existentes (`PDI`, `PMAC`, `PDIS`, `PWEB`, `PDAT`, `POPS`). Marque conflitos e dependências sem apagar issues.
3. Comece por baseline reprodutível (sem alterar comportamento) e por uma issue pequena. Não paralelize edições nas mesmas classes que outro agente esteja implementando.
4. Preserve a ergonomia de `@Autowired` / `@Service` e o contrato de constructor injection gerada na compilação. Não use `T!`, singleton global, reflection per request ou silenciamento amplo de `Sendable`.
5. SwiftNIO continua adapter de rede; não criar scheduler ou GC próprio.
6. Cada PR deve conter hipótese de desempenho, baseline, diffs mínimos, testes e comparação antes/depois; quando não houver medição possível, classificar como correção de segurança/correção, não como ganho comprovado.
7. Não remover validação de request, autorização, limites HTTP, traces mínimos e cuidados de dados para conseguir RPS melhor.
8. Referências ao Spring Boot e comparações correlatas **apenas nos arquivos `.md`**. Não usar esses nomes em código Swift, comentários, scripts, manifests, diretórios de código, labels de CI ou identificadores públicos.
9. Macros locais não fazem discovery global sozinhas. Se a abordagem não funcionar com dois targets SwiftPM, registrar limitação e propor fallback explícito.
10. Entregar relatório final: arquivos alterados, issues mapeadas, testes Linux/macOS executados ou pendentes, benchmark (configuração, mediana, dispersão), riscos e próximo passo.

## Primeira tarefa sugerida

Implementar `PPERF-QA-001`: estabelecer baseline do container DI **atual** em release, verificar requisitos de concorrência e registrar medição. Não fazer refatoração do container na mesma PR. Em seguida trabalhar com o responsável por `PDI-003` na resolução async sem lock atravessando `await`.

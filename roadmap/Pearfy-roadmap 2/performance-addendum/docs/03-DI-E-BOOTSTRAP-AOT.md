# DI e bootstrap AOT — otimização do marco em andamento

## Objetivo

Transformar `@Service`, `@Repository`, `@Autowired` e `@Bind` em **construção previsível**, com componentes descobertos/validados no build/bootstrap e nenhuma pesquisa dinâmica de classes no caminho crítico HTTP.

## Fluxo desejado

1. Macro expande uma declaração local e gera metadados/factory compatíveis com a sintaxe de Swift.
2. Build tool/plugin agrega manifestos por target participante, sem supor reflexão global.
3. Registry gerado contém bindings explícitos, qualificadores, escopos e factories.
4. Bootstrap valida missing/duplicate/circular/scope mismatch e ordem de lifecycle.
5. Contexto instancia singletons e publica grafo imutável para resoluções sem lock de registro.
6. Request scope recebe contexto próprio com término explícito, caso necessário.

## Pontos de desempenho prioritários

- Substituir `NSRecursiveLock` como proteção da factory assíncrona do protótipo **quando a migração async ocorrer**; jamais executar `await` segurando lock de thread.
- Coalescing de singleton concorrente: 100 consumidores aguardam **uma** única factory; erros acordam todos e permitem política de retry documentada.
- Separar **registro/mutação** de **resolução runtime**: registrar novos bindings após `freeze()` deve ser negado, salvo API administrativa explícita.
- Request provider só é resolvido em contexto válido; singleton não mantém acidentalmente objeto request-scoped.
- Evitar `@unchecked Sendable` como solução global; isolar estado mutável em actors/locks pequenos ou snapshots imutáveis.
- Perfis e configuração são resolvidos na inicialização sempre que possível.

## Benchmark DI independente

Medir, com mesmo grafo e build release, (a) bootstrap em 10/100/1000 componentes, (b) resolve singleton repetido, (c) transient factory simples, (d) singleton sob disputa de 1/10/100 tasks, (e) falha de factory e (f) duas aplicações isoladas. Registrar tempo, alocações quando acessíveis, RSS, CPU e comportamento funcional.

## Gate

Nenhum request depende de escanear símbolos, interpretar annotations ou construir o registry. Factory async não causa deadlock; contexto inválido falha antes de abrir listener; tests multi-target compilam no Linux e macOS.

## Nota de implementação

O README do roadmap original contém os IDs `PDI-001`–`PDI-007`, `PMAC-001`–`003`, `PDIS-001`–`002` e `PCTX-001`; este adendo **não os substitui**.

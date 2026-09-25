# Pipeline HTTP: caminho curto, correto e mensurável

## Contrato

Uma rota `@Get("/users/{id}")` deve resolver handler na inicialização e executar em runtime apenas match, binding, validação, chamada e encoding/resposta. `@Autowired` já terá sido resolvido antes de servir requests (exceto escopos deliberadamente dinâmicos).

## Entregas progressivas

**P0:** baseline SwiftNIO vs Pearfy plaintext/JSON; router estável; parâmetros estáticos e dinâmicos; limites de corpo e headers; erro padrão; sem exploração por path traversal.

**P1:** router testado com trie/radix *se* medição mostrar gargalo; minimizar copies e regex; codecs especializados onde possível; serialização tipada; streaming com backpressure.

**P2:** otimizações de middleware pipeline e codecs gerados; evitar geração binária excessiva/compile times proibitivos.

## Checklist por requisição

- Header/body bounds aplicados **antes** da alocação potencialmente descontrolada.
- Timeout total e, quando útil, prazo do downstream.
- Nenhum lock de registro/DI em singleton resolve hot path.
- JSON/UUID inválidos resultam em 400 determinístico, não trap.
- Middleware autenticação, rate limit, logging e tracing não podem ser pulados por rota gerada.
- `GET /plaintext` e `GET /json` possuem exatamente mesmo conteúdo semântico entre comparadores.
- Sem copiar `ByteBuffer` desnecessariamente ou converter bytes para String só para rotear.

## Meta experimental, não promessa

Buscar overhead de throughput baixo do Pearfy sobre SwiftNIO puro em **um benchmark plaintext equivalente**; a sugestão inicial é observar a faixa de até 10%, sujeita à metodologia, ruído e maturidade. Não converter isso em garantia, nem inferir latência p99 ou cenário de banco a partir de plaintext.

# Memória e ownership: usar Swift a favor do Pearfy

## Premissa

Swift utiliza ARC; não criar uma segunda camada genérica de contagem de referências, coletor de lixo ou allocator universal. Em Swift, `struct`, copy-on-write, `borrowing`, `consuming` e tipos não copiáveis são ferramentas **pontuais**, não uma política automática de substituição de DTOs.

## Etapas

1. **Baseline:** RSS idle/peak; heap/alocações disponíveis via profiler; retenções após 10 mil/100 mil requests.
2. **Redução de cópias:** auditar body parsing, String/UTF8/Data/ByteBuffer, serialização, headers e logging.
3. **Pools seletivos:** preservar connection pools, criar buffer pools somente se comprovado ganho líquido e segurança sob concorrência.
4. **Lifecycle:** fechamento de socket, conexão, stream e timer em shutdown/cancelamento.
5. **Diagnóstico:** rastrear crescimento contínuo de RSS, retenção de closures/tasks, ciclos de referência, cardinalidade de cache.

## Observações importantes

- ARC não impede vazamento por ciclos fortes; também não impede uso de RAM elevado por caches, arrays retidos ou buffers.
- `deinit` não substitui fechamento explícito de recurso externo quando a semântica exige ordem e tratamento de erro.
- Reutilizar buffer entre requests pode criar vazamento de dados entre tenants ou corrida de concorrência; preferir lease exclusivo quando necessário.
- `withUnsafeBytes` e ponteiros não são “otimização padrão”: exigem prova por profiler, contrato de lifetime e fuzz tests.
- Evitar armazenar `Request` inteiro em services singleton; preferir dados estritamente necessários.

## Checklist do hotspot de memória

- [ ] Quais alocações vêm do Pearfy, versus runtime/driver/user code?
- [ ] Quantos bytes por request chegam a peak RSS sob 1k concorrentes?
- [ ] Há crescimento sustentado após a fila drenar e o coletor/allocator estabilizar?
- [ ] Há referência forte que prende closure/task/context por tempo indefinido?
- [ ] Logs e traces criam `String` intermediária quando desabilitados?
- [x] O cache local tem TTL, cap de entradas/bytes, isolamento namespace/tenant e LRU; hits/misses/evictions/entries/bytes podem ser enviados ao registry opcional.
- [ ] O custo de sincronização do pool supera a alocação evitada?

## Gate

Toda otimização demonstra melhora em um perfil reproduzível, sem regressão de safety, data isolation ou latência de cauda. Se não melhorar, reverter.

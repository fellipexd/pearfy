# Instruções de aplicação sem sobrescrita

## Opção A — incorporar ao monorepo existente

Copiar `docs/*.md` deste pacote para `docs/performance/` do repositório Pearfy; copiar `backlog/PERFORMANCE-BACKLOG.md` para `docs/performance/PERFORMANCE-BACKLOG.md`; manter README principal intacto, adicionando apenas um link para o novo índice se desejado.

**Não copiar** um `Package.swift` deste pacote (não existe), nem sobrescrever `Sources`, `Tests`, `docs/01-ROADMAP.md`, `docs/06-BACKLOG.md`, `docs/08-DECISOES.md` ou qualquer arquivo em implementação.

## Opção B — manter roadmap aditivo separado

Criar referência no issue tracker: “adendo performance v1.1”; converter cada `PPERF-*` em issues com dependências do backlog original.

## Mudança mínima no README original (opcional)

Adicionar uma única linha dentro da seção de documentação:

```markdown
- [Adendo de performance](docs/performance/01-PLANO-DE-INTEGRACAO.md) — otimizações incrementais, benchmarks e controle de recursos.
```

## Revisão antes de merge

- [ ] Confirmar a arquitetura real do código vigente.
- [ ] Conferir issues concluídas e evitar reabertura desnecessária.
- [ ] Garantir que comparações de marca aparecem somente em `.md`.
- [ ] Confirmar que não se inventaram resultados de benchmark.
- [ ] Priorizar estabilidade do DI sobre micro-otimizações.

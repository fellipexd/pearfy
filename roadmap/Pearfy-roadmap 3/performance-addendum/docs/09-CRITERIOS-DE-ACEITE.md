# Gates de aceite do adendo

## Gate P0 — DI / bootstrap (acompanha marco inicial)

- [ ] API pública e exemplos permanecem compatíveis com o roadmap vigente.
- [ ] Singleton async é criado uma única vez sob 100 resoluções simultâneas.
- [ ] Fábricas com erro/cancelamento não deixam waiters presos.
- [ ] Ciclos, bindings ambíguos e request-scope inválido falham com mensagem útil.
- [ ] Contextos isolados não compartilham singleton.
- [ ] Nenhuma resolução de singleton requer varredura de macros/reflection por request.
- [ ] Medidas repetíveis de bootstrap, resolve e RSS publicadas.

## Gate P0 — Web / NIO (quando fase HTTP chegar)

- [ ] SwiftNIO baseline semanticamente equivalente.
- [ ] Body/header bounds, timeout e deadline testados.
- [ ] Event loops não executam bloqueios longos.
- [ ] Rotas e middlewares continuam corretos sob concorrência.
- [ ] HTTP errors, cancellation e shutdown passam testes.
- [ ] p95/p99, RPS, RSS e erros medidos sob várias concorrências.

## Gate P1 — Data / integração

- [ ] Pool limita conexões e fila; overload não expande memória sem limites.
- [ ] Transação limpa recurso em sucesso, erro e cancelamento.
- [ ] Redis, broker e client HTTP não causam retry storm.
- [ ] Traces e métricas identificam gargalo sem vazamento de dados.

## Gate 1.0 transversal

- [ ] CI Linux/macOS release build + testes.
- [ ] Soak e saturation não deixam crescimento inexplicado de memória.
- [ ] Benchmarks com metodologia e dados brutos publicáveis.
- [ ] Performance não enfraqueceu auth, validação, limites ou isolation.
- [ ] Overhead de módulos opcionais documentado quando habilitados.
- [ ] Qualquer feature ainda experimental aparece como tal.

## Critério de reversão

Reverter otimização se produzir regressão estatisticamente consistente em p99, aumento de erro, duplicação de factory, memory leak, race, data leak, falha de cancelamento ou API frágil sem ganho comprovado.

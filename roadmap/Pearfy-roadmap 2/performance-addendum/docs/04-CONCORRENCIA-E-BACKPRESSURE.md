# Concorrência, admission control e backpressure

## Modelo

SwiftNIO administra rede/event loops; Swift Concurrency gerencia handlers async; Pearfy estabelece **políticas de capacidade**, deadline, cancelamento e execução sob saturação. Isso não é um scheduler de threads alternativo ao runtime Swift.

## Controle por camadas

| Camada | Limite/ação | Sintoma prevenido |
|---|---|---|
| Listener | conexões abertas, timeouts, cabeçalhos | file descriptors/RAM sem limite |
| HTTP | bytes por body, uploads, in-flight | memória proporcional a bodies concorrentes |
| Handler | deadline e fan-out limitado | tasks em cascata sem orçamento |
| DB | pool e fila de espera com timeout | conexão esgotada e fila crescente |
| Outbound HTTP | pool, retry budget, timeout total | amplificação de tráfego |
| Jobs | worker concurrency e queue cap | starvation de requests |

## Regras de engenharia

- Não bloquear event loop com SQL síncrono, compressão pesada, crypto custosa ou filesystem bloqueante. Deslocar trabalho bloqueante para executor apropriado ou usar driver assíncrono.
- Evitar actor único compartilhado que serialize todos os requests. Actors somente para estado mutável que exige isolamento; medir contenção.
- Nunca executar `Task.detached` para “resolver” request scope ou escapar do cancelamento; passagem de contexto e ownership deve ser deliberada.
- Limites podem rejeitar com 429 ou 503 conforme política e causa; não mascarar overload como erro de negócio. Opcionalmente retornar `Retry-After` quando semanticamente válido.
- Cancellation é cooperativo; cliente desconectado não garante que driver, transação ou chamada externa interrompa imediatamente. Documentar limites por adaptador.
- Retry não deve multiplicar fan-out e saturação. Budget global e jitter/backoff quando aplicável.

## Configuração ALVO (não implementada)

```yaml
pearfy:
  concurrency:
    max-in-flight-requests: 1000
    request-timeout: 10s
    max-pending-operations: 2000
    cpu:
      max-parallelism: 8
```

Valores **ilustrativos**, nunca defaults universais: calibrar por CPU, pool, SLAs e teste de carga. Algumas opções requerem decisões sobre que camada as aplica.

## Ensaios obrigatórios

- Carga 1×, 2× e 4× acima da capacidade observada, com RSS e tamanho de fila monitorados.
- Cancelamento por timeout e disconnect, com `defer`/liberação de conexões verificados.
- DB lento e DB indisponível; observar fila, latência p99, erros e recuperação.
- Handler que lança erro durante fan-out; não deixar tarefas órfãs.
- Shutdown durante 1000 requests, com draining limitado e nenhuma operação nova após readiness=false.

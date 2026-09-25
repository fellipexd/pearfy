# Observabilidade da performance

## Métricas para expor quando os módulos existirem

- `pearfy_http_requests_total` por método, template de rota, status class e motivo de rejeição.
- Histogramas de latência de request e outbound, sem labels de ID de usuário ou URL completa.
- In-flight requests, admission queue length, timeouts, cancellations, rejected requests.
- Estado dos pools DB/HTTP; in-use/idle/waiters e tempo de espera.
- Lifecycle startup, readiness e shutdown; falhas de factory/DI.
- RSS, CPU, tasks e event loop lag quando ferramenta/platform adapter suportar medição confiável.

## Regras

- Instrumentação é opt-in por starter quando gerar dependências pesadas, mas health mínimo pertence ao runtime HTTP.
- Diagnósticos internos são protegidos; sem secrets, tokens, SQL contendo dados sensíveis ou IDs de alta cardinalidade.
- Validar custo do tracing com sampling ativo e desativado.
- Não interpretar aumento de latência causado por gerador de carga como evento real do servidor.
- Sinais de overload devem aparecer em métricas, logs e resposta HTTP quando apropriado.

## CLI planejada (NÃO existente ainda)

```text
pearfy benchmark
pearfy profile cpu
pearfy profile memory
pearfy doctor performance
```

Esses comandos deverão integrar profilers e recursos disponíveis no host; não inventar uma API universal que funcione igualmente em todas as versões de macOS/Linux.

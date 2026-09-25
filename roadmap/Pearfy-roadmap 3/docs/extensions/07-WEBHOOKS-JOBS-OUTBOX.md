# 07 — PearfyWebhooks, PearfyJobs, Inbox/Outbox

Infrastructure comum e opcional para integrações, Chatbot, Payments, Notifications e Approvals. `pearfy add webhooks`; `pearfy add jobs --store postgres`. Não instalar mensageria/broker pesado por padrão quando o backend usa banco transacional compartilhado.

## PearfyWebhooks

- Registro tipado de rotas/eventos e política por provider; assinatura HMAC/assimétrica ou segredo específico validado com raw body e comparação segura.
- Contrato de origem/auth e versionamento de eventos; prefixos `@RouteGroup`/Connect quando exportável, mas inbound webhooks não precisam de SDK público.
- Tamanho/tempo máximo; persistir inbox antes de ACK; unique `(provider,tenant,account,event_id)`; dedup, expiração, DLQ e reprocessamento autorizado.
- Eventos sem ID externo: estratégia explicitamente definida e documentada; fingerprint semântica não é chave universal segura.

## PearfyJobs

- Queue durável com `available_at`, estado, número de tentativas, timeout, deadline, bounded concurrency, leases, heartbeat e fencing/token de execução.
- A regra de domínio escolhe idempotência; job worker não presume exactly once quando existe efeito externo.
- Retry só transitório, exponencial+jitter; poison jobs DLQ e intervenção controlada. `Task.detached` não substitui job durável.
- Config de agendamento explicitamente timezone-aware, overlap policy e cancelamento.

## Outbox

- Evento e mutação local na **mesma transação física**, usando conexão compartilhada. Worker publica depois do commit, usa chaves estáveis e regista tentativas/resultados incertos.
- Publicação não é parte de ACID do banco quando transportes externos são independentes; consumidor também deduplica por inbox.

```text
API replica A/B/C → transação e inbox/outbox no banco compartilhado
 → workers concorrentes com lease/fencing → canal/provider → status/reconciliação
```

## Gate

Duplicatas de webhook e retry de worker em 3 instâncias; crash antes/depois de commit e antes/depois de envio; erro de assinatura não entra; lease vencido impede worker obsoleto confirmar; mesmo evento reenviado não duplica efeito financeiro. Simular indisponibilidade do banco/provedor e confirmar limitação de filas/memória.

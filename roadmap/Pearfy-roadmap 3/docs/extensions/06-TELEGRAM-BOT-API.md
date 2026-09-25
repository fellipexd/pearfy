# 06 — PearfyTelegram: adaptador oficial e opt-in

`pearfy add telegram` adiciona produto e config de bot; não exige chatbot nem IA. Integrar Bot API, `setWebhook` e/ou polling como estratégia configurada, **nunca ambos simultaneamente para o mesmo bot**.

## Requisitos

- Verificar `X-Telegram-Bot-Api-Secret-Token` quando webhook configurado; proteger URL e token; limites de payload.
- `update_id`/bot como chave de deduplicação; parse de comandos, callbacks, attachments, status possível; capacidade de teclado/mídia declarada.
- Webhook: persistir duravelmente e responder rápido; reenvios e updates fora de ordem; status de erro classificado; envio com throttling por bot/chat.
- Multi-bot/tenant com particionamento de credenciais e de inbox/outbox.

```yaml
pearfy:
  messaging:
    telegram:
      enabled: true
      bot-token: "${TELEGRAM_BOT_TOKEN}"
      webhook-secret: "${TELEGRAM_WEBHOOK_SECRET}"
```

## Testes

Update repetido em 3 réplicas, secret incorreto, modo polling/webhook conflitante, backpressure, rich content capability, falha de envio, timeout e processamento ordenado por conversa quando requerido.

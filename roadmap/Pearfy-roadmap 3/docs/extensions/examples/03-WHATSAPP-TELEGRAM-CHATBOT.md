# Exemplo conceitual — Messaging/Chatbot e canais

```bash
pearfy add ai
pearfy add messaging
pearfy add webhooks
pearfy add jobs --store postgres
pearfy add chatbot
pearfy add whatsapp
pearfy add telegram
```

Alternativa somente notificações: `pearfy add messaging` + `pearfy add whatsapp` + infra necessária para envio; **não instalar PearfyChatbot/PearfyAI automaticamente**.

```yaml
pearfy:
  ai:
    profiles:
      support-bot:
        provider: local
        model: "${SUPPORT_AI_MODEL}"
        cloud-fallback: false
  chatbot:
    assistants:
      support:
        ai-profile: support-bot
    bindings:
      - { assistant: support, channel: whatsapp }
      - { assistant: support, channel: telegram }
  messaging:
    channels:
      whatsapp:
        access-token: "${WHATSAPP_ACCESS_TOKEN}"
        app-secret: "${WHATSAPP_APP_SECRET}"
      telegram:
        bot-token: "${TELEGRAM_BOT_TOKEN}"
        webhook-secret: "${TELEGRAM_WEBHOOK_SECRET}"
```

Provider `local` e model também precisam existir em `pearfy.ai.providers` antes de iniciar. Nunca logar raw webhooks ou AI prompts com PII. Mensagem de “abrir trava” ou “reembolsar” exige autenticação e autorização de domínio, e aprovação quando definida pela política; IA não concede permissão.

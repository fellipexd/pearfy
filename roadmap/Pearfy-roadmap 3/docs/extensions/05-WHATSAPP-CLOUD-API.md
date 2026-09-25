# 05 — PearfyWhatsApp: adaptador oficial e opt-in

`pearfy add whatsapp` deve funcionar para notificações sem Chatbot. Suporte inicial: **WhatsApp Business Platform / Cloud API oficial**, não automação WhatsApp Web ou scraping.

## Responsabilidades

- Configurar credenciais por business account/phone number com segredo referenciado, webhook challenge/verify e verificação de assinatura com App Secret sobre **raw body** antes de parsear.
- Enviar/receber texto, mídia, templates e botões conforme API real; reportar capabilities e erros de política/janela sem tentar burlar regras do provedor.
- Modelar delivery/status events e cobranças/categorias onde o provedor expuser, com versão explícita de API e datas de atualização.
- Rate limiting, Retry-After, backoff e timeout; token revogado e reauth; idempotência local de webhooks, tracking/reconciliação de envios incertos. Não prometer exactly once de mensagens externas.

```yaml
pearfy:
  messaging:
    whatsapp:
      enabled: true
      phone-number-id: "${WHATSAPP_PHONE_NUMBER_ID}"
      access-token: "${WHATSAPP_ACCESS_TOKEN}"
      app-secret: "${WHATSAPP_APP_SECRET}"
      verify-token: "${WHATSAPP_VERIFY_TOKEN}"
```

## Testes/qualidade

Signature boa/ruim, raw body alterado, desafio cadastro, token ausente, envio template inválido, limites e janela, anexo grande, duplicate webhook, erro temporário permanente, status atrasado, diferentes contas isoladas e secrets redigidos. Verificar documentação oficial e versão API antes de fixar nomes/campos.

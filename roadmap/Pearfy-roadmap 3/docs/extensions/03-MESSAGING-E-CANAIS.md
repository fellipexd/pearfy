# 03 — PearfyMessaging: envelope de mensagens e canais

`PearfyMessaging` é infraestrutura genérica de canais instalada opcionalmente; **não depende de chatbot nem IA**. `PearfyWhatsApp` e `PearfyTelegram` adaptam protocolos dos respectivos fornecedores; `PearfyNotifications` pode usá-los diretamente.

## Interfaces-alvo

- `IncomingMessage`: id externo, channel, account/bot, thread/conversation, sender, timestamp, content, refs de mídia; raw payload não precisa sobreviver na API pública.
- `OutgoingMessage`: destinatário, canal, tipo, conteúdo, template/attachments compatíveis e `deduplicationKey` quando aplicável.
- `MessageChannelAdapter`: parse + validar webhook + enviar + status + capabilities + observabilidade. Preferir resultados tipados a strings.
- Capability negotiation para texto, mídia, botões, template, receipts, streaming e edição: não fingir paridade entre plataformas.

```text
Incoming HTTP webhook → validação de origem/limites → Inbox durável (id único)
 → resposta HTTP rápida → worker com claim/lease → Chatbot/Notification handler
 → Outbox durável → adaptador externo → status/reconciliação
```

**Multi-instância:** banco compartilhado, constraints únicas por (provider,account,external_event_id), concurrency por conversa (lease/fencing/version), retry com backoff/jitter e DLQ; mutex local não impede duas instâncias. Ordenação e entrega exatamente uma vez não podem ser prometidas indiscriminadamente para provedores externos.

## Configuração segura

Webhook recebido: validação BEFORE parse de negócio e BEFORE aceitação. Salvar hash/ID e conteúdo mínimo necessário, com retenção; credenciais env/vault. Rate limiting por conta/tenant; limitar tamanho de mídia; malware scanning em uploads se necessário.

## Aceite

Duas réplicas recebem mesmo webhook -> uma intenção processada; crash após persistir/antes de responder -> replay deduplicado; crash após envio/antes de confirmação -> resultado incerto registrado; token/assinatura inválidos -> evento não entra na inbox; WhatsApp só para notificação sem instalar Chatbot/AI.

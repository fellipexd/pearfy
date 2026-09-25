# 04 — PearfyChatbot: engine especializado de conversa

Instalável via `pearfy add chatbot`, usando `PearfyMessaging` e opcionalmente `PearfyAI`. Bot sem IA para regras/comandos deve ser suportado. Providers não são escolhidos pelo `--ai` de instalação; perfis centrais do `PearfyAI` são configurados no backend.

## Componentes

- Bot registry via compile-time/build-manifest, sem pressupor global scan pelas macros Swift.
- Handlers de comando/mensagem, intents, estado/conversação versionado, contexto minimizado, janela/histórico com retenção, transferência para humano, bloqueios e opt-out.
- Tool calling tipado com schema, authn/authz por recurso/tenant, orçamentos de chamadas e revisão para operações sensíveis.
- API de mensagem neutra de canal; respostas com texto/mídia/botões degradam explicitamente ou falham quando canal sem capability.

```swift
@Chatbot("support")
final class SupportBot {
    @OnCommand("/start")
    func welcome(_ context: ChatContext) async throws -> ChatResponse {
        .text("Olá! Como posso ajudar?")
    }
}
```

**API ilustrativa.** Dependências e contexto precisam ser modelados com Swift 6 strict concurrency; não transportar PII indiscriminadamente para provider LLM. Prompt injection não é autorização.

## Tools de alto risco

`@ChatTool` apenas marca elegibilidade; execução passa por `PearfySecurity` + regras do domínio (por exemplo, PearfyApprovals/PearfyPayments). Chatbot não cancela pedido, reembolsa ou abre trava física com base somente em texto gerado por IA. Confirmar autor/autorização e idempotência externa separadamente.

## Tests

Mensagens reordenadas, repetidas, handoff, tenant mismatch, resposta LLM inválida, tool denegada, tombamento de sessão, expiração, fallback cloud bloqueado, envio com janela/template do canal respeitada.

# 02 — PearfyAI: única camada central de IA no backend

## Posição arquitetural

`PearfyAI` é infraestrutura opt-in responsável por provider/model, credenciais, política de uso, privacidade, timeout, retries seguros, custo, streaming, tools e saída estruturada. Providers locais/cloud são plugins independentes (`PearfyAIProviderOllama`, `...OpenAI`, `...Anthropic`, `...Gemini`), não importados por módulos especializados.

Consumidores: `PearfyChatbot`, `PearfyCRMInsights`, `PearfyMetricAI` e futuros modules requisitam **profile lógico tipado**. NÃO usam endpoints/secrets próprios, NÃO selecionam provider por flag de instalação.

```bash
pearfy add ai
pearfy ai providers list
pearfy ai profile validate crm-analysis
pearfy add crm-insights
```

```yaml
pearfy:
  ai:
    providers:
      local:
        type: ollama
        endpoint: "${OLLAMA_URL}"
      cloud:
        type: openai
        api-key: "${OPENAI_API_KEY}"
    profiles:
      crm-analysis:
        provider: local
        model: "${CRM_ANALYSIS_MODEL}"
        data-policy: crm-minimized
        cloud-fallback: false
      metrics-diagnostics:
        provider: local
        model: "${METRIC_AI_MODEL}"
        data-policy: aggregated-telemetry
        cloud-fallback: false
      support-bot:
        provider: cloud
        model: "${CHATBOT_MODEL}"
        data-policy: support-context
        cloud-fallback: false
```

Configuração ilustrativa: modelo, region, endpoint, quotas, retenção e custos devem ser validados no provider real antes de deploy.

## API-alvo conceitual

```swift
protocol AIService: Sendable {
    func generate<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        profile: String,
        input: Input,
        output: Output.Type
    ) async throws -> Output
}
```

É necessário design adicional para `AIRequest`, `AIResponse`, streaming, tool schemas, cotas, cancelamento e capacidades específicas por provider. A geração de saída tipada exige validação de schema/respostas; não presumir que todo provider ofereça modos nativos equivalentes.

## Políticas centrais

- Segredos exclusivamente no backend (vault/env/secret manager), nunca contrato Connect ou SDK mobile.
- Perfil local/cloud explícito; indisponibilidade do local **não** promove dados para cloud automaticamente.
- Tools invocadas pela IA não herdam permissões ilimitadas: validar usuário, tenant, recurso, ação, rate limit e confirmação humana quando exigida.
- Evitar execuções e tool calls infinitas: orçamento de tokens, tamanho, tempo e número de calls; registrar código de erro e custo sem conteúdo sensível.
- Prompt injection é entrada não confiável; validar fontes e esquemas em tool output.
- Política de dados aplicada antes do adaptador LLM; observabilidade não exporta prompts em claro por padrão.

## Testes

Profiles apontam para providers instalados; cloud fallback negado no profile local; envio a provider errado bloqueado; streaming cancelável; resposta incompatível rejeitada; tool sem permission negada; secrets nunca constam em log/artefatos/stack trace; failover explícito registrado/auditado.

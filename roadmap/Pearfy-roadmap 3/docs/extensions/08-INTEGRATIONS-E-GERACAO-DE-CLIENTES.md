# 08 — PearfyIntegrations e Integration Generator

Objetivo: reduzir boilerplate de APIs externas sem acoplar o domínio aos DTOs do provedor. Produto opt-in (`pearfy add integrations`) e adapters individuais (`pearfy add integration --provider ...`).

```bash
pearfy integration import --openapi ./provider.json --name logistics
pearfy integration adapt logistics --protocol ShippingProvider
pearfy integration check logistics
```

## Entregáveis

- Cliente tipado a partir de OpenAPI (ou contrato equivalente validado); autenticação via backend centralizada por profile (OAuth/API key/mTLS conforme provider), timeouts, retries idempotentes, rate limits e paginação.
- Adapter anticorrupção `ExternalDTO -> DomainDTO`, ownership das respostas, errors tipados e mapeamento de estados desconhecidos. Nunca compartilhar modelo externo como entidade central só por conveniência.
- Mock server e fixtures sanitizadas, contract tests/version check, tratamento de versão e drift externo.
- Policies `retryable`, `idempotent`, cancelamento e circuito (quando escolhido) explícitas; não repetir POST não idempotente automaticamente.

## Connect vs Integrations

PearfyConnect gera SDKs da aplicação Pearfy **para seus consumidores**. PearfyIntegrations importa APIs de **terceiros como clientes do backend**. Podem compartilhar gerador/IR/validators, mas não os limites de autenticação e publicação de contratos.

## Segurança

Avaliar especificações externas como conteúdo não confiável; limitar tamanho e refs remotas, bloquear geração de código perigoso/executar scripts; segredos no servidor; SSRF: base URLs permitidas/validadas. Guardian confere endpoints, idempotência, logs/redação, provider downtime e coverage.

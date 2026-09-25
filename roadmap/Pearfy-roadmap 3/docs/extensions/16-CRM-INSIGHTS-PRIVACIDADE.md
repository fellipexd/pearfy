# 16 — PearfyCRMInsights e integração exclusiva com PearfyAI central

Instalar:

```bash
pearfy add ai
pearfy add crm
pearfy add crm-insights
```

**Não usar** `pearfy add crm-insights --ai ollama`. Provider/model/keys e políticas de exportação são definidos no backend em `pearfy.ai.providers/profiles` (doc 02). CRMInsights recebe apenas o nome de um profile autorizado.

```yaml
pearfy:
  crm:
    insights:
      enabled: true
      ai-profile: crm-analysis
      mode: aggregated
```

## Entregas

- Métricas determinísticas: conversão por estágio, follow-up atrasado, tempo de atendimento, carteira/owner/canal, períodos comparáveis.
- AI opcional: sumarização e análise sobre dados selecionados por services autorizados; evidência/limites/incerteza; recomendações de próximo contato revisadas por humano.
- `aggregated`: grupos com mínimo de amostras e atributos permitidos. `customer-context`: contexto individual depende de finalidade, authz por cliente, minimização, retention e autorização de exportação separada; **cloud off by default**.
- Não fornecer livre acesso SQL à IA, não enviar transcrições inteiras de WhatsApp/Telegram/prompts ou dados financeiros para provider cloud por padrão.
- IA não executa aprovações, altera role, realiza reembolso nem exporta carteira inteira por tool sem PearfySecurity/PearfyApprovals.

## APIs conceituais

```swift
@Service
final class CustomerInsightsService {
    @Autowired var ai: any AIService
    func analyze(_ input: AuthorizedCustomerSummary) async throws -> CustomerInsights {
        try await ai.generate(profile: "crm-analysis", input: input,
                              output: CustomerInsights.self)
    }
}
```

`AuthorizedCustomerSummary` deve ser formado por service CRM após filtro por tenant, ator e finalidade, não a entidade `Customer` serializada indiscriminadamente. Exemplo proposto a adaptar.

## Testes

CRMInsights sem profile falha com erro claro; local unavailable não dispara cloud; usuário sem acesso não obtém resumo; cohort pequeno suprimido; data payload enviado ao provider auditável e sem secrets; token revogado impede export; AI inválida não altera registro de cliente.

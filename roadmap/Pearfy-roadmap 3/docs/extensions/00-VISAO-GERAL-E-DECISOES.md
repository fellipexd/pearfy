# 00 — Visão geral e decisões de arquitetura

**Status:** alvo de implementação. **Escopo:** extensões posteriores a Pearfy Connect v1.3.

## Resultado esperado

O CLI instala capacidades completas (biblioteca + scaffolding + config + migrations + contratos + testes + Guardian), não dependências à toa. Aplicações simples não carregam CRM, pagamento, chatbot, provedores LLM, Datadog ou Grafana sem escolha explícita.

| Camada | Módulos/produtos propostos | Regra |
|---|---|---|
| Core mínimo | PearfyCore, DI, configuração e ciclo de vida; Web segundo template | Sem domínios opcionais |
| Infra opcional | PearfyData, PearfyTransactions, PearfySecurity, PearfyAI, PearfyMessaging, PearfyObservability, PearfyLogs, PearfyMetric, PearfyJobs, PearfyWebhooks, PearfyIntegrations, PearfyConnect | Instalação conforme uso/dep. |
| Domínio opcional | PearfyPayments, PearfyBackoffice, PearfyApprovals, PearfyCRM, PearfyChatbot, PearfyNotifications, PearfyIdentity, PearfyRealtime, PearfyStorage, PearfySubscriptions etc. | Não embutir no core |
| Conectores opcionais | PearfyWhatsApp, PearfyTelegram, AI providers, Log sinks, CRM connectors | Instalar só selecionados |
| Blueprints | customer-support, bko-crm, saas, iot-control, realtime-game | Composição instalável, não novo core |

## Decisões inegociáveis

1. **IA central no backend:** `PearfyAI` resolve providers local/cloud, perfis, credenciais, cotas e política de dados; `PearfyCRMInsights`, `PearfyChatbot`, `PearfyMetricAI` consomem o serviço; proibir `pearfy add crm-insights --ai ollama` como interface de configuração do módulo.
2. **Multi-instância opção A:** réplicas da mesma API acessam o datastore compartilhado; lock e idempotência no banco, não mutex Swift nem uma instância principal gRPC.
3. **BKO:** roles com herança acíclica; grupos organizacionais e escopo de recursos distintos; backend revalida permissão ao solicitar/aprovar/executar; SDK TS para `/bko`.
4. **Aprovações:** exigem 1 ou 2 usuários **adicionais e distintos** do solicitante; vincular a operação e hash canônico de parâmetros; não executar mais de uma vez.
5. **CRM:** instalação independente, conectores para chat/pagamentos separados; IA somente via PearfyAI central e exportação aprovada de dados.
6. **Logs x Observability x Metric:** logs estruturados/eventos; telemetria/traces/contexto; analytics, percentis e regressão, respectivamente. Não duplicar três pipelines no código de negócio.
7. **Privacidade:** padronizar coleta mínima, allowlist de atributos, sanitização ANTES de exportar, contagem mínima, sem corpo/raw SQL/tokens/CPF/saldo na IA cloud por padrão. IA local não é desculpa para coleta sem autorização.
8. **Connect:** `/bko` TS; `/app` iOS+Android; `/public` três; exportação SDK não aplica ACL. Coleções Postman por grupo e cURL por endpoint REST; flows e SDKs são independentes.
9. **Guardian:** orientação via MCP + enforcement por CLI/CI/testes/compilação. Falha/ferramenta ausente = INCOMPLETE/FAIL, nunca sucesso fictício.
10. **Projetos existentes:** não substituir código mais novo por exemplos do roadmap nem remover módulos/rotas sem verificação de dependentes.

## Distinção crucial

`PearfyAI` pode ser genérico, mas os providers são opt-in. `PearfyMessaging` permite usar WhatsApp para notificações sem instalar chatbot. `PearfyCRM` pode existir sem payments, WhatsApp e IA. `PearfyMetric` fornece estatística útil sem IA. `PearfyLogs` deve funcionar com stdout JSON mesmo sem coletor externo.

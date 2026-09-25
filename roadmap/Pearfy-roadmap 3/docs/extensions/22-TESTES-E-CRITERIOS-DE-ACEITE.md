# 22 — Matriz de testes, verificação e critérios de aceite

## Ambiente

- Testar Swift/OS do CI e target de release, 3 processos API reais e datastore compartilhado; não simular multi-instância com só structs em processo único.
- Provider contract tests via mocks+fixtures, mais smoke tests reais **quando credenciais sandbox forem fornecidas**, sem afirmar teste real onde não houve acesso.
- Registrar revisão, versão do driver, isolation level, artefatos e overhead. Falta de suporte => unsupported/fail closed.

## Testes funcionais de instalação

| Caso | Aceite |
|---|---|
| Core mínimo | Compila sem CRM, Payments, Chatbot, SDK de vendor |
| `add crm` | Só deps esperadas; idempotente |
| `add whatsapp` | Funciona sem Chatbot/AI |
| `add crm-insights` | Falha de configuração guiada se PearfyAI profile ausente, não inventa provider |
| `remove` | Não apaga dados/migrations customizadas |
| version conflict | Falha explícita com plano de recuperação |

## Multi-instance fault matrix

- Webhook duplicado em 3 API replicas, antes/depois ACK e commit.
- Outbox persistida porém provider timeout, confirmação incerta e replay.
- Lease expirado, worker antigo tenta finalizar, fencing impede escrita obsoleta.
- Duas aprovações simultâneas, mesmos/diferentes usuários, revogação entre decisões.
- Mesmo requestId financeiro atravessando réplicas, somente um efeito legítimo.
- CRM data access cross-tenant sempre negado, independentemente do SDK e controller.

## Observability/log/metric

- Canary secret/PII em exception, metadata, SQL input e body: ausência em stdout, OTLP e prompt externo.
- OTLP collector caído: API segue operando e drop counter informa perda, buffer limitado.
- percentis histogram aggregated versus valores conhecidos; média ponderada entre réplicas (não média de p95).
- URL concreta/UUID fora dos labels; query shape normalizada, sem binds.
- baseline/versão de deploy e amostra mínima; IA reporta evidência e lacunas, não causalidade inventada.

## IA e CRMInsights

- Profile local falha sem enviar cloud; provider/model configurados só em `pearfy.ai`; texto do cliente tratado como untrusted; schema output incompatível rejeitado; tool sem permissão falha.
- Customer-context cloud não exporta sem aprovação explícita; aggregate report com pequeno N suprimido; offline e cancelamento controlados.

## Backoffice

- Role inheritance com cycle rejeitado; scoped groups testados; permission revocation e cache; export/request/approve/execute testados separadamente; requester nunca aprova; duas outras identidades reais distintas; alteração de payload invalida decisão; audit persiste.

## Aceite final

Somente declarar pronto com testes realmente executados + logs/redacted artifacts + docs + CLI help + `Package.swift` constraints + migration SQL + lint/build; qualquer etapa inviável explicitada como pendente, sem inventar links ou números de desempenho.

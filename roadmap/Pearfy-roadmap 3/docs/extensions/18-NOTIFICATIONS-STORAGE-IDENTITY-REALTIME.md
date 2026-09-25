# 18 — Próximos facilitadores opcionais

Não são pré-requisitos do PearfyBackoffice nem do PearfyLogs; os contratos abaixo são backlog para tornar as soluções instaláveis sem crescer o Core.

## PearfyNotifications

`pearfy add notifications`: centraliza templates, preferências, locale, consentimento, destinos e retries de e-mail/push/SMS/WhatsApp/Telegram. Depende da camada Messaging somente para canais compatíveis; nunca aciona cobrança/canal por surpresa; rate limit e outbox; unsubscribe/opt-out quando aplicável. Providers instaláveis.

## PearfyStorage

`pearfy add storage --provider s3`: contrato de objetos, upload privado, signed URL curta, limites/tipo real, antivírus quando necessário, lifecycle/retention, audit/ownership e adaptadores S3-compatíveis/Azure/GCS etc. Não presumir que S3-compatível equivale em todas as features. Nenhum secret no SDK Connect.

## PearfyIdentity

`pearfy add identity`: sessões, MFA, recuperação e devices, OIDC/OAuth2 social e federado via plugins. PearfyBackoffice aproveita identity mas RBAC/approvals continuam domínio do Backoffice. Proteção contra account enumeration, sessão revogada, consent e step-up para ações de maior risco.

## PearfyRealtime

`pearfy add realtime`: WS rooms/presence/subscriptions tipados para APIs multi-instância. Banco/Redis/mensageria para fanout durável conforme capacidade; ws disconnect/reconnect, replay cursor, ordering declarada e não prometida por padrão. UI/SDK via PearfyConnect.

## PearfyImport

`pearfy add import`: CSV/XLSX streamed, chunk validate, row error reports, idempotência, progresso/job durável, limites de arquivo e mapeamento para modelos de domínio. Import não executa migração de schema automaticamente.

## PearfyAudit

`pearfy add audit`: trails duráveis de actions/perms/approvals e dados minimizados. Não misturar com PearfyLogs best-effort. Retention, acesso restrito, imutabilidade lógica e correção por novos eventos; política legal depende do deployment.

## PearfySearch / FeatureFlags / MultiTenant / Subscriptions

- `pearfy add search --provider ...`: query typed, índice com sincronização/rebuild, escopo tenant e ACL em resultados; adaptadores opcionais.
- `pearfy add feature-flags`: OpenFeature quando compatível, avaliações auditáveis, rollout determinístico por chave estável (não salvar PII in label), não substituir auth.
- `pearfy add multitenancy`: tenant isolation em query/services/worker/cache e migrações, certificação por storage, testes cross tenant.
- `pearfy add subscriptions`: plans, quotas, trials, lifecycle; gateway payment provider instalado separadamente, idempotência e reconciliação billing.

## Aceite

Dependências explícitas por módulo e provider, fixture sem cloud account, contratos separados, mínima pegada de instalação, segurança de tenant e teste multi-instância nas capacidades que compartilham estado.

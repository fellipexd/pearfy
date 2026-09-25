# v1.5 — decisões, módulos e limites

| Área | Decisão | Anti-padrão |
|---|---|---|
| Núcleo | Pequeno, extensões independentes via CLI e SwiftPM | Importar social/chatbot/financeiro na API mínima |
| Social | Domínio genérico orientado a atores, conteúdo, grafo e feed | IDs de game/troféu no núcleo |
| Aplicações consumidoras | Integração por APIs e adapters estáveis; cada domínio de produto permanece no app | Acoplar regras específicas de um app ao framework |
| Identity | Login social independente de PearfySocial | Tratar login Google como rede social |
| Persistência identity | `user_social_accounts` opcional com relacionamento ao usuário existente | Fundir usuários automaticamente por e-mail |
| IA | PearfyAI é configuração **runtime** única para local/cloud e perfis; DevKit IA de desenvolvimento é separado | Provider escolhido por `pearfy add crm-insights --ai ...` |
| Harness | Registry + Skills + Agents + MCP + CLI + gates independentes Guardian | Agente certifica seu próprio código |
| Multi-instância | Cada réplica acessa diretamente datastore transacional compartilhado | Primary gRPC obrigatório; mutex local como integridade |
| Connect | Grupos exportam targets; SDK não concede autorização | Considerar código TS oculto uma ACL |
| Data | Models desejados, migrations revisáveis, adapters certificados; PostgreSQL é o primeiro adapter suportado | Alterar schema em produção no startup |
| Deployment | Contracts compatíveis, rollout controlado e rollback planejado | Reverter SQL destrutivo cegamente |

## Camadas

`PearfyCore` → infra opt-in (`Data`,`Transactions`,`Security`,`Connect`,`AI`,`Jobs`,`Webhooks`,`Logs`,`Metric`) → módulos domínio opt-in (`Social*`,`Identity`,`SocialLogin`,`Payments`,`Backoffice`,`CRM`) → adapters e domínios pertencentes à aplicação consumidora.

## Semântica dos exemplos

`@SocialContentType`, `@Measured`, `@RouteGroup`, `@ChatTool`, `@RequiresApproval`, `@SocialLoginProvider` e outras macros nestes documentos são **propostas**. Implementar por contratos viáveis; Swift macros isoladas não descobrem todas as fontes. Não usar código fictício como produção.

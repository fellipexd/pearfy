# PearfySocial — módulo genérico para redes sociais

## Objetivo

Resolver problemas recorrentes de redes como Facebook, Instagram, X e comunidades: ator social, privacidade, grafo, conteúdo, comentários, feed, moderação, notificações e extensões de domínio. **Não replicar UI, algoritmos proprietários nem afirmar paridade com plataformas comerciais.**

## Pacotes e comandos propostos

```bash
pearfy add social                  # social core + dependências necessárias
pearfy add social-graph
pearfy add social-content
pearfy add social-feed
pearfy add social-communities
pearfy add social-moderation
pearfy add social-notifications
pearfy add social-media
pearfy add social-messaging       # somente se houver mensagens privadas
pearfy add social-insights        # sem configuração de provider dentro do módulo
pearfy blueprint add social-network
```

Cada pacote é produto SwiftPM independente, versionado e instalável; resolver grafo e dependências em `pearfy modules plan`. Core pode compor um preset mínimo, porém não compilar dependências não instaladas. `SocialMessaging` reutiliza Messaging/Realtime e não é requisito de posts.

## Dependências e ownership

| Contrato | Dono |
|---|---|
| Conta, token, login | PearfyIdentity/PearfySecurity ou adapter da aplicação |
| Perfil/ator social | PearfySocialCore |
| Seguir/amigo/bloqueio/mute | PearfySocialGraph |
| Post/comentário/reação/repost | PearfySocialContent |
| Seleção, ordenação, paginação de feed | PearfySocialFeed |
| Denúncia, revisão, apelação | PearfySocialModeration |
| Domínio específico da aplicação consumidora | Adapter versionado pertencente à aplicação |
| IA de moderação e análise | PearfyAI central + policy do módulo |

## Não funcionais

Escopo por organização onde aplicável, ACL por recurso, IDs configuráveis com UUIDv7 padrão, transações e constraints compartilhados multi-instância, dedup/outbox, cache invalidável, audit separado de logs, paginação por cursor, política explícita de exclusão e retenção. Observabilidade por templates de rota, sem identificadores pessoais em labels.

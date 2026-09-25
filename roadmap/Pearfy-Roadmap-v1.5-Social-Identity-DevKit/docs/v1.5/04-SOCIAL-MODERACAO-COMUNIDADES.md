# Moderação, comunidade, notifications e IA

## Moderação genérica

`ContentModerationPolicy`, `ModerationProvider`, `ModerationDecision`, `ContentReport`, `Appeal`, `ReviewQueue` e auditoria. Estados `pending/approved/rejected/restricted`, especificar transições; decisões referenciam `contentRevision`, impedindo aprovação antiga liberar edição nova. Políticas específicas são fornecidas pela aplicação consumidora; IA usa perfil no PearfyAI central.

## Comunidades

Actor comunitário, membresia, `communityRole`, visibility, políticas de postagem, ban/mute temporário, moderação e escopo de recursos. Permissões comunidade não devem se tornar roles globais de BKO. Considerar rate limits, spammers, abuso, retenção e fluxo de apelação.

## Notifications

Gatilhos comment/reaction/follow/mention/moderation sobre event outbox; dedup por eventId+recipient+kind; preferências, bloqueio, batch/digest e providers opt-in. Notificação não pode mostrar trecho de conteúdo que deixou de ser visível. Transporte WS/push não garante entrega; persistent inbox cursor quando requerido.

## IA

`PearfySocialInsights` e moderador consomem PearfyAI com perfil autorizado; IAM de ferramentas tipadas, no cloud fallback silencioso. Conteúdo de usuário é input não confiável e pode conter prompt injection; nunca conceder decisões administrativas por output livre do modelo. Moderation false positive/human appeals avaliados.

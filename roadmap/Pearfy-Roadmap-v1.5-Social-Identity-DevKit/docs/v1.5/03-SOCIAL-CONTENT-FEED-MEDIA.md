# Conteúdo e feed extensível — posts, comments, reactions

## Content types

Post com autor, audience, estado, texto estruturado, anexos via PearfyStorage e `contentReference` tipada por schema versionado. Conteúdo especializado pertence ao domínio da aplicação; PearfySocial oferece comentários/reactions/repost para referências tipadas.

Exemplo **conceitual**:

```swift
@SocialContentType("gaming.achievement")
struct AchievementActivity: Codable, Sendable {
    let gameId: UUID
    let achievementId: String
}
```

## Post, comment e reaction

Post content revision, `moderationStatus`, `visibility`, `created_at`; comentário parent/path ou closure table avaliada por escala; edição reabre moderação se policy exigir; exclusão propaga invalidation. Reações com `UNIQUE(actor_id, target_type, target_id, reaction_kind)` e operação toggle atômica sem duplicação. Repost referencia objeto canônico com ACL e retentiva de edição/removal.

## Feed pipeline

1. Candidate source (`chronological`, `following`, `community`, `discovery`, custom adapter).
2. Visibility + block + moderation gate no momento de servir.
3. Rank/ordenação explícita e reproduzível por versão.
4. Cursor com critério total estável (timestamp + id), limite.
5. Hydration em lotes sem N+1; anexos por referência autorizada.
6. Cache e invalidação por evento idempotente; nunca cache público com payload privado.

MVP: cronológico e following via queries indexadas. Crescimento: projeções e fanout assíncrono medidos antes de adotar ranking complexo. Feed candidato ≠ direito de visualizar; `get by id` não pode desviar ACL. Indexação search respeita privacy. Métricas p50/p95/p99, queries por item, taxa de content filtering, cursor stability.

## Entrega

`pearfy sdk generate` para targets de cliente configurados pelo projeto consumidor. Eventos tipados com schema/versão, outbox. Nenhum SDK exporta conteúdo privado em schema aberto.

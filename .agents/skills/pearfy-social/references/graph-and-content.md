# Social contracts and current boundaries

- Graph contracts and visibility types are in `Sources/PearfySocial/SocialGraph.swift`.
- Generic content drafts, reactions, feed cursors, notification contracts and moderation coordination are in `SocialContent.swift`.
- PostgreSQL support is in the separate `PearfySocialPostgres` product and currently covers graph operations; do not infer content/feed persistence from its existence.
- Keep ownership server-side and validate visibility at read time. Follow/block state can change after publication.
- Moderation provider calls must not hold database transactions open; provider failure and commit failure have distinct retry behavior.
- No media/object storage, durable notification sender or complete multi-replica content outbox is available.

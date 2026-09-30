---
name: pearfy-social
description: Use for Pearfy social actors, graph visibility, posts/comments/reactions contracts, and moderation coordination.
metadata:
  pearfy-module: social
  pearfy-skill-version: 1.0.0
---

# Pearfy Social

Load for social-domain changes only. Check module state with `pearfy ai inspect` and `pearfy modules info social`; the product is partial, not a complete social platform.

## Implemented contracts

Current sources include actors/handles, graph visibility and store contracts, content drafts, cursor/reaction/notification contracts, and a generic moderation worker. Read `references/graph-and-content.md`, then inspect `Sources/PearfySocial/SocialGraph.swift` and `SocialContent.swift`.

## Integrations and restrictions

`social-postgres` persists graph operations only. Durable post/comment/feed storage, an outbox, media, notification delivery and complete privacy-aware feed queries are absent. Load `pearfy-data` for schema/SQL changes and `pearfy-security` for endpoint authorization. Preserve owner identity and recheck visibility on reads; do not assume hidden SDK routes are protected.

## Validate

Run `swift build` and `bash scripts/test-unit.sh`. Run PostgreSQL integration tests when service variables are explicitly available; distinguish graph coverage from the unimplemented content store.

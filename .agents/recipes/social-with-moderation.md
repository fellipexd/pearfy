# Social with moderation

**Status: partial.** `PearfySocial` defines content drafts, moderation revisions/digests and a generic worker/provider protocol. A durable PostgreSQL content store, moderation outbox and production provider adapter are absent.

Load `pearfy-social`, then inspect `Sources/PearfySocial/SocialContent.swift`. Keep provider calls outside transactions. Preserve owner IDs and revalidate visibility at read time. Provider failure differs from commit failure; do not add automatic retries around ambiguous commits. Implement only the application's adapter and tests until the corresponding Pearfy storage module is available.

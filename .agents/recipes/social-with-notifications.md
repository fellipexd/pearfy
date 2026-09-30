# Social with notifications

**Status: planned delivery.** Social notification value/contracts exist, but there is no notification persistence, delivery service, outbox, push provider or read-state runtime module.

Load `pearfy-social` for current notification types. Do not claim send/retry/read receipts or multi-instance fanout. If adding application-owned delivery, define durable idempotency and authorization locally and keep the integration clearly outside Pearfy's available module catalog.

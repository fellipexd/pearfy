---
name: pearfy-banking-mvp
description: Use when continuing a consumer banking MVP with Pearfy's implemented money, ledger, transaction and resource-authorization contracts.
metadata:
  scope: application-workflow
  skill-version: 1.0.0
---

# Pearfy banking MVP workflow

This Skill guides application work. It is not a Pearfy banking product or a
claim that the consumer MVP is present in this repository. First locate and
inspect the actual application, its installed Pearfy products, migrations,
routes and tests. Ask for the application path only if it cannot be found from
the active workspace or user-provided context.

## Implemented framework contracts

- `PearfyLedger` provides `LedgerMoney`, balanced operation/posting contracts,
  durable idempotency and resource-locking protocols.
- `PearfyLedgerPostgres` provides `PostgresFinancialOperationStore`; install
  its schema and use the same SQL transaction for domain writes, result and
  ledger postings. See `docs/LEDGER.md`.
- `PearfySecurity` provides resource authorization with an application-owned
  resolver and policy; authentication and per-resource authorization remain
  separate.
- `PearfyTransactions`, `PearfyData` and `PearfyPostgres` provide existing
  transaction, SQL and PostgreSQL boundaries. Load their Skills before using
  APIs from those modules.
- `payments` is planned. Do not invent `PaymentEngine` or other roadmap APIs.

## Application rules

Keep account ownership, transfer limits, customer status and product policy
in the consumer application. Use integer minor units with an explicit currency
and scale; never use `Double` or `Float` for amounts. Supply stable canonical
parameter bytes and a scope/key for every retriable financial command. Include
all mutable resources in `resourceKeys` before reading their state, then check
authorization and business invariants while protected by the transaction.
Each ledger operation must balance by currency and scale. After
`TransactionCommitOutcomeUnknown`, reconcile by the same idempotency key before
retrying. Do not perform remote effects inside a callback that may be retried.

Load the resource within the authorized tenant/ownership scope; a client ID or
global role alone is not permission. If authorization can change concurrently,
revalidate it inside the transaction that mutates the resource. For reliable
external publication, use an application-owned outbox row in that transaction
and design consumers for at-least-once delivery and deduplication.

## Current validation limits

This Pearfy checkout contains framework contracts, not the user's consumer
banking application. The last recorded integration environment lacked
`PEARFY_TEST_POSTGRES_HOST`; therefore PostgreSQL schema, decimal round-trip,
multi-client race and actual unknown-commit behavior still require real-server
validation. Idempotency has no expiry, there is no built-in outbox, and no
framework feature certifies regulatory compliance or production readiness.
Report each check as PASS or INCOMPLETE from executed evidence.

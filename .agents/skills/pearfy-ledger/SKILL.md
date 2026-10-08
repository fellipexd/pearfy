---
name: pearfy-ledger
description: Use for exact money, append-only ledger entries, durable idempotent PostgreSQL operations, and resource locks.
metadata:
  pearfy-module: ledger
  pearfy-skill-version: 1.0.0
---

# Pearfy ledger

The ledger module is installable with pearfy add ledger. It provides the
PearfyLedger contracts and PearfyLedgerPostgres adapter. payments remains
planned and does not provide an API.

## Contracts

- LedgerMoney stores signed Int64 minor units with a caller-supplied
  three-letter uppercase currency code and scale from 0 through 9. Decimal
  parsing rejects excess fractional digits; no implicit rounding is performed.
- FinancialOperationStore.perform binds the callback, idempotency record,
  result bytes, and optional balanced postings to one physical PostgreSQL
  transaction.
- The caller supplies stable canonicalParameters; the adapter hashes their
  exact bytes. Reusing a scope/key with different bytes is a conflict.
- resourceKeys are locked with PostgreSQL transaction advisory locks in
  bytewise sorted order. Include every resource whose state is read or changed,
  including every posted account ID.
- Balances are derived as credits minus debits from the append-only entries.

## Failure and limits

Failed transactions leave no operation key or postings. A successful retry with
the same key and parameter bytes returns the stored result without invoking the
callback. After TransactionCommitOutcomeUnknown, call reconcile with the same
scope, key, and parameters before attempting a new operation.

PostgreSQL serialization failures and deadlocks can be retried as a whole unit
when maximumAttempts is configured above one. The callback must perform no
remote or external side effects. There is no idempotency expiry or outbox in
this version. Do not treat these contracts as banking policy or production
certification.

See docs/LEDGER.md for setup, schema, authorization guidance, and tests.

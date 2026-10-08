# Pearfy Ledger

ledger is an installable framework module for exact money values, balanced
append-only postings, persistent idempotency and transaction-scoped resource
locks. It does not implement a payment provider, bank-specific rules, account
ownership, a currency registry, or a consumer application.

Install the products in a managed Pearfy application with:

    pearfy add ledger

The module contains:

- PearfyLedger: LedgerMoney, posting and operation contracts, and the
  FinancialOperationStore / FinancialResourceLocking protocols.
- PearfyLedgerPostgres: PostgresFinancialOperationStore and
  PostgresFinancialResourceLocker.

## Exact money

LedgerMoney uses signed Int64 minor units with an explicit uppercase
three-letter currency code and scale from 0 through 9. The application chooses
the scale; Pearfy does not infer it from a global currency table. Parse from a
decimal string or provide minor units directly. Decimal parsing rejects excess
fractional digits instead of rounding. Integer overflow is rejected.

SQLValue.decimal(Double) remains available for compatibility and retains its
floating-point semantics. SQLExactDecimal and .exactDecimal add a bounded,
validated base-10 spelling that the PostgreSQL adapter binds as NUMERIC.
Financial ledger entries use integer minor units, not this SQL decimal variant.

## Atomic operation flow

Start PearfyPostgresDatabase, construct PostgresFinancialOperationStore,
and call installSchema() before use. The adapter records the idempotency
fingerprint, operation result bytes, and any postings in the same PostgreSQL
transaction as the callback's SQL statements.

The caller supplies a scope, key, and deterministic canonicalParameters
bytes. Pearfy hashes the exact bytes with SHA-256. Applications should include
all operation-defining values and tenant/operation scope in this representation.
Equivalent values encoded as different bytes are treated as different
parameters. A matching key and digest returns the previous result and does not
call the operation closure; a matching key with a different digest returns
LedgerError.idempotencyConflict.

The operation callback receives the existing SQLTransaction. Keep its work
inside that transaction: do not make HTTP calls or perform other external side
effects. If serialization failures or deadlocks are retried by configuring
maximumAttempts, the entire callback can run again after PostgreSQL confirms
the prior transaction rolled back.

There is no persisted processing row visible outside the transaction. A
transaction-local PostgreSQL advisory lock serializes concurrent requests for
the same scope/key; the first committed result wins. An error before commit
rolls back the operation key and postings. TransactionCommitOutcomeUnknown
does not mean rollback: call reconcile(scope:idempotencyKey:canonicalParameters:)
first. Reconciliation acquires the same transaction lock, waits for an earlier
attempt to settle, and returns the committed result or nil.

Resource locks use a separate advisory-lock namespace from migration locks and
are acquired in deterministic UTF-8 byte order. Pass every resource key before
the callback reads state. Every account ID receiving a posting must also be in
resourceKeys. This lock is per PostgreSQL database and transaction; it does
not coordinate another database, a cache, or a remote service.

## Ledger rules

Each posted operation has at least two debit/credit entries. Debits and credits
must sum exactly for every currency and scale. The adapter validates this
before writes, and a deferred PostgreSQL constraint trigger checks the committed
operation again. Triggers reject UPDATE and DELETE on operation and entry
tables, and only allow new entries in the transaction that created the owning
operation. These controls protect normal application roles; database
superusers/owners can still change schema or disable triggers.

Balances are calculated from credit minus debit over immutable entry rows.
There is no balance projection and no API that treats a projection as
authoritative. Reads become more expensive as ledger history grows; no
snapshotting or reconciliation projection is included.

## Resource authorization

Authentication remains separate from authorization. SecurityMiddleware
authorizeResource requires an authenticated principal, resolves a resource
through application-supplied code, then asks an application-supplied
ResourceAuthorizationPolicy. The default policy denies all. A role alone
does not grant access to a particular resource.

The resolver must load the resource within the tenant/ownership scope instead
of trusting a client-supplied ID. When access policy can change concurrently,
revalidate it inside the same transaction that changes the resource. Pearfy
does not define universal ownership or tenant rules.

## Delivery and validation

No outbox is included. Use an application-owned outbox row in the same
SQLTransaction when durable event publication is required. A separate
publisher can provide at-least-once delivery; consumers must deduplicate, and
there is no exactly-once guarantee beyond the local PostgreSQL transaction.

Unit tests cover money parsing and posting validation. PostgreSQL integration
tests require PEARFY_TEST_POSTGRES_*; without a real configured server the
adapter, DDL triggers, multi-client races and unknown-commit reconciliation are
not verified.

---
name: pearfy-transactions
description: Use when coordinating database units of work, nested REQUIRED calls, rollback-only state, cancellation, or unknown commit outcomes.
metadata:
  pearfy-module: transactions
  pearfy-skill-version: 1.0.0
---

# Pearfy transactions

Use when a use case writes through one transactional store or when nested operations must share a physical transaction. Check `pearfy modules info transactions` and the implementation version with `pearfy ai inspect` first.

## Contracts and integration

The standalone `transactions` product provides generic REQUIRED propagation, a unit-of-work contract, rollback-only propagation and typed classification of unknown commit outcomes. Read `references/transaction-boundary.md` and inspect `Sources/PearfyTransactions/TransactionManager.swift`. The PostgreSQL adapter integrates this contract through `pearfy-postgres`.

## Restrictions

Atomicity applies only to resources enlisted in the same physical transaction. Do not claim cross-database atomicity or retry an unknown commit as if it were a known rollback. Keep remote calls outside the open transaction and use durable outbox patterns only where an implemented module supplies them. Cancellation and nested failures must preserve rollback semantics.

## Validate

Run `swift build` and `bash scripts/test-unit.sh`; when PostgreSQL transaction integration changes, run the relevant configured integration tests. Guardian results must be reported with their actual scope.

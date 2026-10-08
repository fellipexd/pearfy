---
description: Implements a narrow banking-MVP application slice using existing Pearfy APIs.
mode: subagent
---

Load `pearfy-banking-mvp` and the Skills for installed modules used by the slice. Inspect the consumer application before editing; do not add bank-specific rules to the Pearfy framework. Use exact `LedgerMoney`, `FinancialOperationStore`, the PostgreSQL adapter and resource authorization only as their current contracts permit. Keep state checks, idempotency, balanced postings and domain writes in one transaction. Use the Pearfy CLI to create or modify managed applications. Add focused unit and real-PostgreSQL integration coverage; report unavailable services as INCOMPLETE and never claim production readiness.

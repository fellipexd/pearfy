# Test matrix v1.5

## Segurança/auth

OAuth exp/issuer/audience/state/nonce, first-login concurrent, link cross-account deny, user unlink last method deny, role/tenant/actor ownership, private content by direct URL & feed/search/cache, block and mute changes. SDK export cannot bypass server ACL.

## Concorrência/estado

3+ réplicas compartilhando banco; duplicate follows/reactions, out-of-order events, comment vs moderation revision, idempotent notification, retry/unknown commit, session and signup races; zero duplicate external side-effects when mock controls guarantee protocol.

## Feed

Stable cursor timestamp+ID, pagination inserts/deletions, privacy filters pre/post cache, n+1 query budget, large account fanout under bounded workload, timeline p95/p99 baselines.

## DevKit

Repo with missing modules, API planned but not implemented, skill version mismatched, MCP denied operation, simulated failed test, prompt injection in module docs, out-of-scope filesystem, redacted report, re-run idempotent.

## Evolução de schema

Versioned migrations apply once, checksum drift blocks, concurrent runners serialize, rollback plans are explicit, schema diff preserves existing data, and consumers can upgrade one module without changing unrelated capabilities.

## Definição de entregue

Build/release, unit+integration+security+race/fault, contract+data parity, privacy export review, docs, CLI invocation, telemetry and rollback runbook; PASS com logs/evidence/hash da revisão. Sem ambiente/credencial real -> BLOCKED/INCOMPLETE, jamais green fictício.

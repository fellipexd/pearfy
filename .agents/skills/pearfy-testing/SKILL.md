---
name: pearfy-testing
description: Use for Pearfy test contexts, isolated dependency overrides, and framework test setup.
metadata:
  pearfy-module: testing
  pearfy-skill-version: 1.0.0
---

# Pearfy testing

Use when changing test fixtures or isolated dependency overrides. Confirm the product with `pearfy ai inspect`; inspect `Sources/PearfyTesting/TestContext.swift` and `references/test-context.md`.

## Current capability

`PearfyTesting` provides test-context overrides for dependency registrations. The project also uses Swift Testing, local unit/integration scripts and optional PostgreSQL/Redis service variables; those are package practices, not APIs supplied by PearfyTesting.

## Restrictions and validation

Keep test overrides scoped and isolated; do not leak mutable test state across tests. Missing external service configuration means an integration gate is not run and must not be reported as passing. Run `swift build` and `bash scripts/test-unit.sh`; run configured integration tests for adapter changes. Guardian independently reports build, test and environment status.

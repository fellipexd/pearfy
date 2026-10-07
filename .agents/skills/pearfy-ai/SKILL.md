---
name: pearfy-ai
description: Use for Pearfy application runtime chat, embeddings, structured workflows, and official Codex CLI subscription integration; not for editing development-agent configuration.
metadata:
  pearfy-module: ai
  pearfy-skill-version: 1.1.0
---

# Pearfy application AI client

Use only when application code makes model/chat calls. This is distinct from OpenCode or the DevKit harness. Check module installation and exact client version with `pearfy ai inspect`.

## Implemented behavior

`PearfyAI` provides an OpenAI-compatible chat/embeddings client, typed workflow/RAG contracts, the typed Jev decision client, and an optional adapter that invokes the official `codex exec` CLI. Read `references/runtime-client.md` and inspect the referenced source before using provider contracts. Codex mode relies on the worker user's existing Codex sign-in and account quotas.

## Security and integration

API provider credentials belong to server-side configuration/secret management and must not enter mobile SDKs, contracts, logs or prompts. Codex OAuth remains managed by Codex CLI; Pearfy must not read/replay its token or call undocumented Codex endpoints. Keep Codex in an ephemeral read-only work directory, avoid inheriting API-key environment variables, and rely on structured output. RAG/storage adapters remain application-owned; the PearfyAI contracts do not imply a built-in vector database or graph runtime.

## Validate

Run `swift build` and `bash scripts/test-unit.sh`. Use the explicit stub transport for deterministic unit tests; remote calls require deliberate staging configuration and are not run by the default tests.

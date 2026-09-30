---
name: pearfy-ai
description: Use for Pearfy application runtime chat calls to OpenAI-compatible endpoints, not for development-agent configuration.
metadata:
  pearfy-module: ai
  pearfy-skill-version: 1.0.0
---

# Pearfy application AI client

Use only when application code makes model/chat calls. This is distinct from OpenCode or the DevKit harness. Check module installation and exact client version with `pearfy ai inspect`.

## Implemented behavior

`PearfyAI` provides an OpenAI-compatible chat client over `PearfyCloud`. Read `references/runtime-client.md` and inspect `Sources/PearfyAI/OpenAICompatibleClient.swift` before using request/response types.

## Security and integration

Provider credentials belong to server-side configuration/secret management and must not enter mobile SDKs, contracts, logs or prompts. Use explicit secure remote endpoints and bounded transport behavior. Do not assume this product implements agent planning, retrieval, tool execution, chatbot workflows or multi-provider governance.

## Validate

Run `swift build` and `bash scripts/test-unit.sh`. Use the explicit stub transport for deterministic unit tests; remote calls require deliberate staging configuration and are not run by the default tests.

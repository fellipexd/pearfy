---
name: pearfy-devkit
description: Use for the optional Pearfy development dashboard, its route/metrics API, providers, CLI and harness behavior.
metadata:
  pearfy-module: devkit-ui
  pearfy-skill-version: 1.0.0
---

# Pearfy DevKit

Use for local development tooling and the `PearfyDevKitUI` product. This is not application runtime AI. Check installed module/Skill versions with `pearfy ai inspect`; read `references/dashboard-and-data-sources.md` and a file in `.agents/recipes/` only when that exact integration applies.

## Current behavior

The UI is opt-in, bearer-protected and served by the application. Routes come from the live router. Installing DevKit adds a bounded in-process request trace/error collector with route templates, status and duration; it never captures concrete paths, query values, bodies, headers or exception messages. The runtime also exposes a bounded recorder for completed background-work traces containing only safe work names, timing and outcome. An adapter can expose allowlisted HTTP counters/histograms; richer spans, logs, queries and host resources require explicit providers. Missing sources are shown as unavailable, never populated with demo data.

## Restrictions and validation

Disabled by default; require a strong token when enabled and bind local deployments to loopback. Never capture request/response bodies, credentials, cookies or SQL bindings. CPU/RSS per route is not available as an exact measurement. Use `pearfy devkit doctor|start|export`, then run `swift build` and `bash scripts/test-unit.sh`. DevKit MCP tools are not currently implemented.

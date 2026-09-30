---
name: pearfy-gateway-lab
description: Build deterministic in-process fake integrations with PearfyGatewayLab.
pearfy-module: gateway-lab
pearfy-skill-version: 1.0.0
---

# PearfyGatewayLab

Use the optional `PearfyGatewayLab` product for deterministic, in-process HTTP fakes. Read `references/sdk.md` for the verified API.

- Fakes have no live-network fallback; unmatched requests fail closed.
- Scope fixture sequences and mutable state by `GatewayLabContext.runID`.
- Keep configured scenarios within `GatewayLabLimits`; release tracked-run capacity with `reset(runID:)`.
- Validate `GatewayLabConfiguration` before registering an integration. Fake mode is forbidden in production and rejects public live endpoints.
- Journals contain method, path, outcome, status, and run ID only. Never add headers, query values, bodies, credentials, or personal data.
- There is no payment port in this checkout. Do not create payment APIs until a real domain contract exists.

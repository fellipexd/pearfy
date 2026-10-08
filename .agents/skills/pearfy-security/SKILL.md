---
name: pearfy-security
description: Use for server-side authentication, authorization middleware, API keys, JWT validation, and security-sensitive route policy.
metadata:
  pearfy-module: security
  pearfy-skill-version: 1.0.0
---

# Pearfy security

Load for authn/authz changes or when exposing any endpoint. Confirm the installable `security` module and exact APIs through `pearfy ai inspect`, `pearfy modules info security`, and `Sources/PearfySecurity/Security.swift`.

## Available behavior

The current product contains HMAC JWT validation, API-key authentication, Bearer middleware and role-based route policy. Read `references/authentication-and-policy.md` before editing. Route groups and client SDK exports do not grant access; the server must authorize every request.

## Rules

For HTTP endpoints, prefer `@Authenticated`, `@PermitAll`, or `@RolesAllowed` when their route-level policy exactly matches the reviewed requirement. They declare route access policy; they do not authenticate credentials, configure identity providers, or install the required security middleware. Review `.agents/skills/pearfy-core/references/macros.md` for their scope.

Default to deny, validate issuer/audience/time/signature according to the configured contract, and keep keys outside source, logs, contracts and mobile bundles. Legacy JWTs without `kid` require an explicitly configured single fallback key. Do not infer ownership from a request field or email address. Redact credentials and authorization headers from diagnostic records.

## Integrations and validation

Use the `http` module for route access hooks and `data`/`postgres` only when policy requires durable state. Run `swift build` and `bash scripts/test-unit.sh`; add tests for denied access, role boundaries and key rotation for policy changes. Guardian does not currently certify all security policies.

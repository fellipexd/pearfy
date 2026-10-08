---
name: pearfy-connect
description: Use for HTTP route groups, typed contract IR, request/response schema metadata, and OpenAPI export.
metadata:
  pearfy-module: connect
  pearfy-skill-version: 1.0.0
---

# Pearfy Connect

Use when changing API grouping, public contract metadata, or schema discovery. Verify installed products and version with `pearfy ai inspect` and `pearfy modules info connect` before designing a client-facing API.

## Current implementation

This checkout implements route groups, operation metadata, typed request/response schema references and OpenAPI route export. Prefer `@RouteGroup` for literal route groups and `@ContractModel`/`@ContractField` for Codable types whose fields fit the current schema macro; these macros describe contract metadata and do not generate SDK clients. Read `references/route-contracts.md` and the exact limits in `../pearfy-core/references/macros.md`; inspect `Sources/PearfyConnect/ContractCompiler.swift` and `Sources/PearfyWeb/HTTPRouteGroup.swift`.

## Important boundary

SDK generation, contract diff, Postman/cURL generation and compatibility checks are not implemented. Do not invoke or document `pearfy sdk generate` as usable. SDK target selection is not authorization. Preserve real server paths and only export routes belonging to an explicit group; avoid silently widening a group's target policy.

## Integrations and validation

Use `pearfy-core` for route registration and `pearfy-security` for server authorization. Run `swift build` and `bash scripts/test-unit.sh`; validate deterministic IR and schema references when modifying contracts. Guardian does not yet certify Connect compatibility.

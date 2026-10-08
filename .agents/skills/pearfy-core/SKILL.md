---
name: pearfy-core
description: Use for Pearfy application bootstrap, HTTP routes, dependency injection, configuration, lifecycle, and controller macros.
metadata:
  pearfy-module: http
  pearfy-skill-version: 1.1.0
---

# Pearfy core and HTTP

Use when creating or changing an application entry point, route/controller, dependency binding, configuration, or lifecycle component. Confirm the selected products with `pearfy ai inspect`; this Skill maps to the installable `http` module and includes the base HTTP application products.

## Prerequisites and available contracts

Use a Pearfy-managed Swift package, or inspect its actual `Package.swift` before editing. Current code provides `HTTPRouter`, `HTTPRequest`/`HTTPResponse`, `PearfyHTTPServer`, `ApplicationContext`, configuration loading, DI/request scopes, controller macros and static route discovery. Read `references/http-and-lifecycle.md` for route registration and `references/dependency-injection.md` for scopes/bindings. Relevant sources are `Sources/PearfyWeb/`, `Sources/PearfyContext/`, `Sources/PearfyDI/`, `Sources/PearfyConfiguration/` and `Sources/PearfyMacros/`.

When no architecture style is declared, default new application code to Clean Architecture and record `architecture.style: clean`. The business profile does not choose the architecture style. Preserve an explicitly declared style. Keep domain independent of Pearfy/infrastructure, application use cases in Application, adapters in Infrastructure, HTTP controllers in Presentation, and wire them in an explicit composition root. Use `@Service` for actual services/use cases and only use persistence or API-schema macros where their documented semantics apply; no generic domain-model macro exists. Do not create empty layers or fake repositories just to match a diagram. See `docs/ARCHITECTURE.md`.

## Integrations and constraints

Use `pearfy add <module>` only for an available registry entry. Prefer the applicable public Pearfy macros over equivalent hand-written HTTP route or component registration. For HTTP, `@RestController` plus supported verb, binding and route-policy annotations is the default; always call its generated `__pearfy_registerRoutes(in:instance:)` explicitly because no automatic controller discovery exists. Read `references/macros.md` for the exact inventory and boundaries.

Use direct `HTTPRouter` route registration only when a dynamic or infrastructure requirement has no suitable macro; record a concrete reason in the change/migration output. Security middleware owns authentication and authorization enforcement; controller policy macros only declare route access metadata. Route groups only describe contracts. Register routes and middleware before router freeze. Avoid global service locators and request-path cardinality in metrics. The current HTTP server does not supply TLS or WebSockets.

## Validate

Run `swift build` and `bash scripts/test-unit.sh`; use the matching focused router, macro, DI, or lifecycle tests when changing those contracts. `pearfy guardian verify` is an independent build/test/environment gate, not a complete security certification.

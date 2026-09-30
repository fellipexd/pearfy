---
name: pearfy-core
description: Use for Pearfy application bootstrap, HTTP routes, dependency injection, configuration, lifecycle, and controller macros.
metadata:
  pearfy-module: http
  pearfy-skill-version: 1.0.0
---

# Pearfy core and HTTP

Use when creating or changing an application entry point, route/controller, dependency binding, configuration, or lifecycle component. Confirm the selected products with `pearfy ai inspect`; this Skill maps to the installable `http` module and includes the base HTTP application products.

## Prerequisites and available contracts

Use a Pearfy-managed Swift package, or inspect its actual `Package.swift` before editing. Current code provides `HTTPRouter`, `HTTPRequest`/`HTTPResponse`, `PearfyHTTPServer`, `ApplicationContext`, configuration loading, DI/request scopes, controller macros and static route discovery. Read `references/http-and-lifecycle.md` for route registration and `references/dependency-injection.md` for scopes/bindings. Relevant sources are `Sources/PearfyWeb/`, `Sources/PearfyContext/`, `Sources/PearfyDI/`, `Sources/PearfyConfiguration/` and `Sources/PearfyMacros/`.

## Integrations and constraints

Use `pearfy add <module>` only for an available registry entry. Security middleware owns authorization; route groups only describe contracts. Register routes and middleware before router freeze. Avoid global service locators and request-path cardinality in metrics. The current HTTP server does not supply TLS or WebSockets.

## Validate

Run `swift build` and `bash scripts/test-unit.sh`; use the matching focused router, macro, DI, or lifecycle tests when changing those contracts. `pearfy guardian verify` is an independent build/test/environment gate, not a complete security certification.

# Dependency injection

- Inspect `Sources/PearfyDI/ServiceContainer.swift` for the available registration, scope and resolution APIs before adding a binding.
- Resolve dependencies during construction. Do not add a service locator to controllers or resolve globally on each request.
- Validate the graph before startup; distinguish singleton, transient and request scope, and never let a singleton retain a request-scoped dependency.
- Use `PearfyContext` for application lifecycle and `PearfyConfiguration` for typed configuration. Keep infrastructure imports outside `PearfyCore` and `PearfyDI`.
- `PearfyTesting` supplies isolated test-context overrides; test scope caching and cleanup where bindings change.

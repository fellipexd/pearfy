# HTTP and application lifecycle

- Register controllers/routes and middleware before `HTTPRouter.freeze()`; the router rejects later registrations.
- Route identities are declared templates (`/users/{id}`), not concrete request paths. `contractOperations()` exposes method, template, group and type metadata without handlers.
- `PearfyHTTPServer` freezes its router at startup. Pair it with `ApplicationContext` lifecycle components for ordered start and reverse stop.
- `HTTPRequest` enforces path traversal, body/header limits and normalized headers. Return typed `HTTPResponse` values; do not place request bodies or credentials in route metadata.
- Macros/discovery only include symbols supported by the current target/plugin. Inspect generated registry artifacts and tests; do not assume runtime reflection.

Source of truth: `Sources/PearfyWeb/HTTPRouter.swift`, `HTTPTypes.swift`, `Sources/PearfyNIO/HTTPServer.swift`, `Sources/PearfyContext/ApplicationContext.swift`.

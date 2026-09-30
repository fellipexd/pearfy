# Route contract reference

- `HTTPRouteGroup` declares a logical name, prefix, SDK-target metadata and contract version.
- `HTTPRouter.contractOperations()` returns registered method/path templates and request/response type names; it does not expose handlers.
- `ContractCompiler` consumes current route and discovered schema metadata to build deterministic contract IR.
- `openAPIDocument` can export registered routes; no SDK code generator or contract diff command exists in this checkout.
- Route group and SDK-target metadata restrict export only. Authorization remains in `PearfySecurity` and application middleware.
- Discover actual macro output and tests before adding a schema type; documentation examples are not compiler support.

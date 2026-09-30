# Authentication and authorization

- Inspect the concrete middleware and error contracts in `Sources/PearfySecurity/Security.swift`.
- Authentication establishes request identity; route access/roles enforce authorization. Both are server-side.
- API keys must be compared according to the current authenticator implementation and never echoed in errors.
- JWT fallback for missing key ID is an explicit compatibility choice with one configured fallback key; do not widen it to an arbitrary key set.
- Route groups, generated SDK contents and hidden UI controls are not access controls.
- Add regression tests for unauthenticated requests, wrong roles, malformed/expired tokens and rotation when those cases apply.

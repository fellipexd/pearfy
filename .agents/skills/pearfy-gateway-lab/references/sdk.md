# GatewayLab SDK contract

Import `PearfyGatewayLab`. `GatewayLabProviderRegistry` records typed provider capabilities. `FakeHTTPProvider` accepts explicit method/host/path fixtures, ordered responses, virtual delay, and timeout/reset/malformed-response faults. Requests without a fixture throw `noMatchingFixture`; this provider never performs network I/O. Fixture counts, response sizes, tracked runs, and journal entries have hard bounds exposed by `GatewayLabLimits`.

Create a `GatewayLabContext` for each isolated run. Its run ID scopes fixture sequence state and journal entries. The virtual clock advances deterministically by fixture delay. Call `reset(runID:)` to reset a run's sequences and release tracked-run capacity. The journal retains its newest entries up to the configured limit; unmatched request paths are redacted.

Call `GatewayLabConfiguration.validate()` during app composition. Production + fake, and fake/sandbox modes targeting a public host, are rejected. No mode silently changes to another adapter.

No real Payments protocol exists in this checkout, so a payment fake is not part of this product yet.

# Test context reference

- `Sources/PearfyTesting/TestContext.swift` contains current override and context APIs; confirm signatures there.
- The package's test target uses Swift Testing and has separate unit/integration scripts.
- PostgreSQL/Redis integration gates use `PEARFY_TEST_*` environment variables. An unconfigured service is INCOMPLETE/not run, not a pass.
- Add meaningful behavior/contract tests; avoid cloning an implementation with a tautological test.
- `pearfy guardian verify` is an independent build/test/environment slice, not a full security, schema or release certification.

# E2E contract verification

`pearfy migrate verify` runs a logical request against `PEARFY_LEGACY_URL` and
`PEARFY_URL`, then compares status, selected headers and normalized response
bodies. Select a route/domain or `--all`. Route/path/query/body inputs require
explicit OpenAPI examples/defaults; arbitrary identifiers are not invented.

Configured normalizers support ignored JSON paths, ISO-8601 timestamps and
unordered arrays. Requests refuse redirects and each response is bounded to
2 MiB. Writes require `--allow-writes` plus
`PEARFY_MIGRATION_SANDBOX=1`; remote endpoints require HTTPS and an explicit
remote opt-in. Authorization is passed through the process environment and is
never emitted to logs, cURL output, result files or the model context.

Results under `.pearfy/e2e/results/` contain route key, statuses, comparison
dimensions, byte counts and duration, but no response body, request headers or
credentials. Only a passing comparison changes a route to `verified`.
`pearfy migrate finalize` refuses unverified/conflicting route contracts.

This first slice compares supplied fixtures and is not a traffic replay engine
or a substitute for isolated write-test environments.

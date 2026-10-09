# Pearfy migration subsystem (CLI 0.1.0)

The migration CLI is contract-first. It records discovered behavior and its
evidence before implementation; it does not translate source syntax or claim
that discovered routes have already been ported.

## Commands implemented in this checkout

```bash
pearfy init my-api --profile standard-api
pearfy adopt --path ./existing-pearfy-app
pearfy inspect --path ./legacy-app
pearfy migrate --framework spring-boot
pearfy baseline
pearfy sync
pearfy sync --apply
pearfy doctor
pearfy architecture check
pearfy migrate status routes
pearfy migrate status elements
pearfy migrate domain users
pearfy migrate route --route 'GET /users/{id}' --state mapped
pearfy migrate element --id 'service:src/UserService.java:UserService' --state implemented
pearfy migrate curl --route 'GET /users/{id}'
pearfy migrate verify --route 'GET /users/{id}'
pearfy migrate finalize
```

`pearfy new` remains an alias for the default `pearfy init` profile. `inspect`
does not write files. `sync` is a preview unless `--apply` is supplied. Baseline
and migration commands preserve existing route progress and never rewrite
application source files.

The architecture style is separate from the business profile. New projects
default to Clean Architecture (`clean`); adoption and baseline preserve a style
already present in the Pearfy manifest and default to `clean` when that field
is absent. Migration remains contract-first and does not rewrite legacy source.
See [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md) for layer boundaries and the
current macro semantics.

## Project files

- `pearfy.project.yml` — versioned traceability manifest. The CLI writes JSON,
  which is valid YAML 1.2, so standard-library tooling can encode it without a
  third-party YAML dependency. Hand-edited block YAML is also accepted for the
  supported subset.
- `.pearfy/architecture.yml` — selected profile and declared architecture
  decisions.
- `.pearfy/migration/legacy-contract.yml` — routes, schemas, evidence,
  confidence, conflicts and migration states.
- `.pearfy/history.jsonl` — small, value-free CLI event records.
- `.pearfy/e2e/results/` — sanitized per-route outcomes; response bodies,
  request headers and credentials are never stored.

The analyzer is bounded to 5,000 files, 1 MiB per file and 32 MiB total text.
It skips build/dependency directories and symbolic links. Its implemented
extractors cover OpenAPI/Swagger JSON and the supported YAML subset, Postman
collection routes with body values reduced to schemas, Spring semantic
annotations, NestJS route decorators, ASP.NET Core route/authorization
attributes, Laravel `Route` declarations, FastAPI decorators, SQL
`CREATE/ALTER TABLE` targets, Liquibase table declarations, Express-like Node
routes, Go router method/path registrations, and simple frameworkless PHP
method/URI comparisons. Evidence records relative paths and summaries, not
source lines or Postman credentials/examples.
When a local Git repository is present, baseline also inspects at most 20
recent commit path lists (never commit messages or diffs) for deleted legacy
build descriptors.
Unsupported or ambiguous evidence remains review work instead of being guessed.

The migration CLI only discovers and records contracts and route progress. It
does not generate controllers or migrate database code. `pearfy migrate status routes`
and `pearfy migrate status elements` also classify available macro
guidance as `applicable`, `not-applicable`, or `not-supported`; a recommendation
does not rewrite source or assert semantic parity. Supported literal HTTP
verbs prefer `@RestController` and the matching route macro when implementing
the new endpoint. The generated route registrar must still be called explicitly.
Parameter conversion, handler behavior, policy expressions, and persistence
semantics require source review; unsupported cases stay open and include a
reason. Update a route through
`discovered → contracted → mapped → implemented`; `verified` is reserved for a
passing E2E comparison. `finalize` refuses open/conflicting route contracts.
For an adopted Pearfy Swift application, `pearfy architecture check` also
reports direct static HTTPRouter registrations under `Sources/` that may map to
route macros; classify each as converted or a documented dynamic/infrastructure
exception. This diagnostic is advisory and does not modify source.

## E2E comparison safety

Set `PEARFY_LEGACY_URL` and `PEARFY_URL`. Remote endpoints require HTTPS and
`PEARFY_MIGRATION_ALLOW_REMOTE=1`. The runner refuses redirects, times out each
request, and caps response bodies at 2 MiB. Path/query/body inputs must come
from explicit OpenAPI examples/defaults. POST/PUT/PATCH/DELETE additionally
require `--allow-writes` and `PEARFY_MIGRATION_SANDBOX=1`; remote write endpoints
also require the remote opt-in. Set `PEARFY_LEGACY_AUTHORIZATION` and
`PEARFY_AUTHORIZATION` separately when the two APIs use different credentials,
or use `PEARFY_MIGRATION_AUTHORIZATION` for a shared value. Credential values
are not printed or saved. `pearfy migrate curl` emits environment-variable
references and fixture-file placeholders, never fixture values.

Optional `.pearfy/e2e/settings.yml` supports `comparison.ignore`,
`comparison.timestamps.normalize`, `comparison.arrays.<json-path>.order`, and
`comparison.headers`. Response comparison checks status, selected headers and
normalized bodies. Results contain only statuses, mismatch dimensions, byte
counts and duration.

## Known scope boundary

This is the initial migration slice, not deep semantic conversion for every
framework in the roadmap. AsyncAPI, GraphQL, Protobuf, ORM relationship/schema
reverse engineering, broad framework DI/security/transaction semantics, traffic
replay, generated application code and automatic E2E fixture synthesis remain
future work. These adapters currently extract routes/evidence; they do not
claim full semantic mapping. No unsupported Pearfy module APIs are generated or
implied.

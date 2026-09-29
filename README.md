# Pearfy — performance roadmap addendum (v1.1)

> **Supplementary, incremental addendum** to the main roadmap. It does not
> renumber milestones 0.1–1.0 or replace accepted contracts; implementations in
> this checkout correspond to the completed PPERF issues described below.

## Purpose

Add a **performance by design** dimension to the existing roadmap: less work per
request, resource and concurrency limits, measurable optimizations, and
operational diagnostics. Borrow ideas from Go, Rust, Java, and Node.js without
transplanting runtimes or rewriting SwiftNIO, ARC, or Swift's scheduler.

**Assumed starting point:** the first roadmap is under implementation. An earlier
prototype used `NSRecursiveLock` and synchronous factories in `ServiceContainer`;
that **does not mean the user's current implementation still works that way**.
Inspect the current source before applying any issue from this addendum.

## Reading order

0. `docs/IMPLEMENTADO-E-TESTADO.md` — current checkout state, verified coverage, and known limits.
1. `docs/01-PLANO-DE-INTEGRACAO.md` — how to integrate with the existing project without starting over.
2. `docs/02-ARQUITETURA-DE-PERFORMANCE.md` — responsibility boundaries and decisions.
3. `docs/03-DI-E-BOOTSTRAP-AOT.md` — component resolution and ahead-of-time generation.
4. `docs/04-CONCORRENCIA-E-BACKPRESSURE.md` — limits, cancellation, and queues.
5. `docs/05-MEMORIA-E-OWNERSHIP.md` — ARC, buffers, and resources.
6. `docs/06-HTTP-E-SERIALIZACAO.md` — the request critical path.
7. `docs/07-BENCHMARKS-E-REGRESSAO.md` — methodology and metrics.
8. `docs/08-OBSERVABILIDADE-E-OPERACAO.md` — production visibility.
9. `docs/09-CRITERIOS-DE-ACEITE.md` — milestone gates and regression requirements.
10. `docs/10-DECISOES-E-ANTI-PADROES.md` — supplementary ADRs.
11. `docs/11-IDEIAS-DE-OUTROS-ECOSSISTEMAS.md` — reference mapping.
12. `backlog/PERFORMANCE-BACKLOG.md` — identified issues and dependencies.
13. `integration/PROMPT-PARA-AGENTE.md` — a ready-to-use prompt for incremental implementation.
14. `integration/CHANGESET.md` — files to add without overwriting existing ones.

## Preserved contracts

- Pearfy remains the exclusive name and identity in source code.
- Swift 6.x strict concurrency, macOS and Linux, and Swift Package Manager.
- `@Autowired` / `@Inject` provide ergonomics over constructor injection; no `T!` or global resolution through getters.
- Multi-target static discovery remains a goal; do not claim a standalone macro scans an entire package.
- HTTP and infrastructure dependencies remain outside Core/DI/Context.
- Security, observability, and tests remain cross-cutting; performance does not justify removing checks.

## Current implementation in this checkout

This checkout implements DI/request scopes, context and lifecycle; HTTP/NIO and
Route Groups; component/entity macros and discovery; opt-in `@ContractModel` /
`@ContractField` Connect schemas for Codable DTOs, aggregated per target by the
plugin; UUIDv7, SchemaIR, and an initial PostgreSQL compiler; a versioned JSON
migration catalog, checksum/drift detection, planning, and transactional locking;
`PearfyTransactions` with REQUIRED propagation over the physical PostgreSQL unit;
Connect IR with operation/auth metadata and typed schema references; a versioned
Module Manager; local stdio MCP with specialized tools enabled only explicitly by
the project; a module-based Skills-first catalog; `pearfy guardian verify`, scoped
to builds/tests and integration-environment configuration; JWT/API-key validation
and policies; parameterized SQL; local/Redis cache; in-memory/Redis broker; local
fixed-delay scheduler; outbound HTTP client with limits/retry/circuit breaker;
OpenAI-compatible chat adapter; health/readiness/Prometheus metrics; and opt-in
PearfyDevKitUI. Guardian v1.5, operational Social Content, and other items remain
partial or unavailable; the matrices and `docs/AI-SKILLS-FIRST.md` record evidence
and gaps.

The CSVs in `Benchmarks/Baselines/` are local measurements, not SLAs; current
baselines are associated with local commit `ce5bef0`. The AOT snapshot has a
reproducible check in `bash scripts/verify-aot-snapshot.sh`. Roadmaps 2/3/v1.5 are
archived in `roadmap/`; implementation matrices list pending gates.
`benchmark-observability.sh` compares HTTP metrics enabled/disabled, while
`benchmark-modules.sh` measures local in-memory/stub adapters.

This checkout passed 136 tests in the DevKit v1.7 slice; `bash scripts/test-unit.sh`
passed 129 tests in the earlier Populate snapshot. Populate adapter tests connect
only when `PEARFY_TEST_POSTGRES_HOST` is configured; this environment did not run
against a real PostgreSQL service or perform a volumetric benchmark. The
`pearfy guardian verify` run on September 25 built and ran 115 Debug tests, then
returned INCOMPLETE because PostgreSQL/Redis were unavailable. The latest
historical run with real PostgreSQL/Redis services had 101 tests, before the Social
Content/Guardian contracts, PostgreSQL/JWT legacy settings, and PearfyPopulate:

```bash
bash scripts/test-unit.sh
bash scripts/test-integrations.sh
bash scripts/test-integrations.sh -c release
```

To run the local integrations, start PostgreSQL/Redis and use
`bash scripts/test-integrations.sh` (accepts `PEARFY_TEST_POSTGRES_*` and
`PEARFY_TEST_REDIS_*`).

The `.github/workflows/performance.yml` workflow runs Release builds on macOS/Linux;
Actions test suites are temporarily paused while Swift 6.2 failures are
investigated. HTTP reports remain manual/weekly and non-blocking; tests are
available locally through `scripts/test-unit.sh` and
`scripts/test-integrations.sh`. Pending roadmap 2/3/v1.5 gates are listed in
`roadmap/` matrices. CPU/memory profiling falls back to `sample`, `heap`, and RSS
(`ps`) on this host.

## Available CLI

```bash
swift run pearfy new my-api
cd my-api
swift build
swift run MyApi
swift run pearfy benchmark
bash scripts/benchmark-observability.sh --runs 5 --http-requests 500
bash scripts/benchmark-modules.sh --runs 5 --resolves 1000 --concurrency 10
swift run pearfy profile cpu -- ./MyApi
swift run pearfy doctor performance
swift run pearfy guardian verify
python3 scripts/soak-http.py --target .build/debug/MyApi --duration-seconds 60 --workers 16
bash scripts/verify-aot-snapshot.sh
pearfy modules list
pearfy modules plan --add postgres
pearfy modules plan --add populate
pearfy ai init --client opencode
pearfy ai inspect
pearfy ai doctor
pearfy ai mcp list
pearfy sdk versions
pearfy add devkit-ui
pearfy devkit doctor
pearfy devkit start
pearfy ai sync
```

The scaffold uses an absolute local path to this Pearfy checkout; use
`--framework-path` or `PEARFY_FRAMEWORK_PATH` to select another checkout.
Profiling uses `xcrun xctrace` when available; on this host CPU profiling uses
`/usr/bin/sample` and memory profiling samples RSS with `ps`. Linux can use
`perf`, `heaptrack`, or `valgrind`. See `swift run pearfy --help`.

`pearfy guardian verify` runs `swift build` and `scripts/test-unit.sh`, inspects
service variables referenced by tests, and returns 0 (PASS), 1 (FAIL), or 2
(INCOMPLETE). This first slice does not replace CI gates for security, contract
parity, schema/SQL, or release.

## PearfyPopulate v1.6

`PearfyPopulateCore`, `PearfyPopulatePostgres`, and the `pearfy populate` command
implement the first functional slice of the data populator. Managed Pearfy
projects can install the module with `pearfy add populate`; projects that do not
select it do not add its libraries to their application products. The executor
supports PostgreSQL introspection, optional reconciliation with
`.pearfy/schema.json` and applied migrations, deterministic hash-bound plans,
preview, limits, batch checkpoints, idempotent resume, status/verify/report, and
PostgreSQL-measured size metrics.

```bash
pearfy add populate
pearfy ai sync
pearfy populate inspect --environment local
pearfy populate plan --table public.notes --rows 100 --seed 42 --environment local
pearfy populate preview --plan .pearfy/populate/plans/PLAN.json
pearfy populate run --plan .pearfy/populate/plans/PLAN.json --approve-plan-hash HASH --environment local
pearfy populate status --run RUN_ID
pearfy populate verify --run RUN_ID --environment local
pearfy populate report --run RUN_ID
```

The same plan accepts `--target-size 2GB --size-mode total`; `GB` is decimal and
`GiB` is binary. `inspect`, `profile`, and `plan` require `--environment`; profile
only accepts aggregates in a local read-only transaction. Execution blocks
production-like target names, requires a loopback host for `local`, validates
migrations and the model manifest, requires approval to exactly match the plan
hash, and rejects triggers, RLS, partitions, unsupported constraints, and
relations without eligible existing parents.

This slice does not create parent tables, automate migrations, implement `COPY`,
cleanup, or PearfyMetric analysis. See `docs/PEARFY-POPULATE.md` for implemented
formats, commands, and limits. No 2 GB benchmark has been recorded in this
checkout.

## PearfyDevKitUI v1.7

`PearfyDevKitUI` is an optional SwiftPM product. Add the Pearfy package and the
`PearfyDevKitUI` and `PearfyObservability` products to the application target. It
serves a local authenticated dashboard and discovers route templates directly
from the router. The `MetricsRegistry` adapter exports only known HTTP metrics
for registered method/template pairs; existing counters are cumulative for the
process lifetime. Request traces are collected in-process. Completed
background-work traces can be recorded through `DevKitWorkTraceRecorder` and a
`JobScheduler` execution observer. Redacted logs, CPU/RSS, and storage remain
pluggable sources and are shown as unavailable when they are not connected; the
dashboard never uses simulated data.

```bash
PEARFY_DEVKIT_ENABLED=true PEARFY_DEVKIT_TOKEN='local-development-token-longer-than-16-chars' swift run MyApi
```

The token is required whenever the product is enabled, including in development;
the default configuration keeps the UI disabled. See
`docs/PEARFY-DEVKIT-UI.md` for package setup, router installation, telemetry
limits, and endpoints.

## Skills-first

`AGENTS.md` contains only global rules. Technical knowledge lives in
module-versioned Skills under `.agents/skills/<skill>/SKILL.md`; references are
opened on demand. Use `pearfy ai init --client opencode`, `pearfy ai inspect`,
`pearfy ai sync`, and `pearfy ai doctor` to prepare and verify the workspace. The
CLI preserves edited Skills and reports conflicts; `pearfy add/remove` synchronizes
Skills for selected products. OpenCode uses project-local adapters and does not
modify `~/.config/opencode`. MCP starts without Pearfy tools; enable a module for
an explicit dynamic operation with `pearfy ai mcp enable <module>` and revoke it
when finished. See `docs/AI-SKILLS-FIRST.md` and
`docs/AI-CONTEXT-MEASUREMENTS.md`.

## Naming rule

Comparisons with Spring Boot may appear only in `.md` documentation. New source,
test, script, manifest, workflow, and symbol names must use only Pearfy and neutral
technical terminology.

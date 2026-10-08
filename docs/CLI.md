# Pearfy CLI 0.1.0 lifecycle

```bash
pearfy init api --profile standard-api
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
pearfy migrate verify --route 'GET /users/{id}'
```

`new` remains an alias for `init`. Supported initial profiles are
`standard-api`, `financial-transactional`, `social-community`,
`realtime-game-server`, `iot-backend`, `high-traffic-platform`, and `custom`.
Module selection is resolved through the installed Module Registry; no
roadmap-only products are introduced.

When no architecture style is declared, `pearfy init` records Clean Architecture
(`clean`) and scaffolds Domain, Application, Infrastructure, and Presentation
responsibilities. This default is independent of the selected business profile.
The generated HTTP example uses a purposeful `@Service` use case and
`@RestController`; its composition root explicitly registers generated
components and routes. It does not create a placeholder repository because it
has no persistence. Existing projects retain a style already recorded in
metadata; adoption/baseline uses `clean` when the style is missing. See
[`docs/ARCHITECTURE.md`](ARCHITECTURE.md) for dependency direction and macro
selection rules.

`inspect` performs read-only analysis. `baseline` requires detected Pearfy
products/source and preserves existing migration progress. `migrate` analyzes
a legacy project and records its contract; it does not rewrite application
code. `sync` is preview-only unless `--apply` is supplied. See
`docs/migration/README.md` for E2E safety and analyzer limits.

`migrate status elements` lists extracted controllers, services, repositories,
models, transactions, authorization rules, validation, jobs and events. After
review, use `pearfy migrate element --id <element-id> --state <state>` to record
mapping/implementation progress. `finalize` requires each structural element
to be implemented or explicitly ignored. Route/element status includes macro
guidance; the contract-first migrator does not rewrite application source.
See [the public macro inventory](MACROS.md) and
[`docs/migration/README.md`](migration/README.md) for selection and limits.

## Application development commands

Run these commands from the root of a Swift package that contains an executable
target:

```bash
pearfy dev
pearfy start
pearfy build
```

`dev` runs the app in `debug` and restarts it when Swift sources or package
manifests change in the app or a resolved Pearfy dependency. It requires
[`watchexec`](https://github.com/watchexec/watchexec) (`brew install watchexec`
on macOS). `start` runs the app in `release`; `build` builds the package in
`release`. For packages with multiple executable products, choose one with
`--product`:

```bash
pearfy dev --product MyAPI
pearfy start --product MyAPI -- --port 8080
pearfy build --product MyAPI
```

Use `--configuration debug|release` to override the configuration. Arguments
after `--` are passed to the executable by `dev` and `start`. These commands
delegate compilation and execution to SwiftPM and keep its incremental build
cache in use.

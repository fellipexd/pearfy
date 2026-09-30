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

`inspect` performs read-only analysis. `baseline` requires detected Pearfy
products/source and preserves existing migration progress. `migrate` analyzes
a legacy project and records its contract; it does not rewrite application
code. `sync` is preview-only unless `--apply` is supplied. See
`docs/migration/README.md` for E2E safety and analyzer limits.

`migrate status elements` lists extracted controllers, services, repositories,
models, transactions, authorization rules, validation, jobs and events. After
review, use `pearfy migrate element --id <element-id> --state <state>` to record
mapping/implementation progress. `finalize` requires each structural element
to be implemented or explicitly ignored.

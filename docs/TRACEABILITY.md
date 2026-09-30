# Pearfy project traceability

CLI-managed projects use `pearfy.project.yml` (schema version 1) to record the
project name, Pearfy/CLI `0.1.0` versions, entry mode, provenance, origin
confidence/evidence, architecture profile, enabled products and migration
progress. The CLI serializes JSON, which is YAML 1.2 compatible. It does not
copy environment values or credentials into the manifest.

`pearfy inspect` is read-only. `pearfy baseline` reconstructs a missing
manifest for an existing Pearfy project while preserving route states.
`pearfy sync` previews drift; `pearfy sync --apply` is required to reconcile
the manifest and Legacy Contract.

Detailed, value-free lifecycle events are appended to
`.pearfy/history.jsonl`. Missing tracking is reported as a baseline/adopt task,
not silently treated as a new project.

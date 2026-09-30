---
name: pearfy-jobs
description: Use for local fixed-delay scheduled jobs and cooperative job shutdown.
metadata:
  pearfy-module: jobs
  pearfy-skill-version: 1.0.0
---

# Pearfy jobs

Use for in-process fixed-delay scheduling. Verify the installed `jobs` module with `pearfy ai inspect`; consult `references/scheduler.md` and `Sources/PearfyJobs/JobScheduler.swift`.

## Current capabilities and limits

The scheduler supports named jobs, avoids overlapping runs for its local scheduler and stops cooperatively. State is process-local. Durable scheduling, leases shared across replicas, cron/time-zone semantics and an outbox worker are not implemented.

## Integrations

Use `pearfy-messaging` only when a job genuinely publishes/consumes messages; use `pearfy-transactions` for one database unit of work. Keep job handlers idempotent and honor cancellation. Do not describe a local fixed-delay task as a distributed job queue.

## Validate

Run `swift build` and `bash scripts/test-unit.sh`; test duplicate names, interval bounds, no overlap and stop behavior when changing scheduler contracts.

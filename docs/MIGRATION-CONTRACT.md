# Canonical Legacy Contract

The CLI stores the contract at
`.pearfy/migration/legacy-contract.yml`. Generated content is JSON syntax, a
valid YAML 1.2 document, while the loader accepts the supported block-YAML
subset for hand-edited manifests and OpenAPI files.

The current contract records route IDs, HTTP method/path, OpenAPI parameters,
request/response schemas and examples, security scheme names, implementation
references, evidence/confidence, conflicts, domain and migration state. It also
records typed semantic elements for supported Spring annotations (controllers,
services, repositories, models, transactions, authorization rules, validation,
jobs, and event listeners) and OpenAPI component schemas. These elements feed
per-kind migration progress but are not generated into Pearfy application code.

Evidence contains relative file paths and summaries, not source excerpts.
Conflicting status/schema evidence is retained as a conflict. The analyzer
does not decide which source is correct and does not generate application
code.

See [`docs/migration/README.md`](migration/README.md) for the exact analyzer
boundary and CLI usage.

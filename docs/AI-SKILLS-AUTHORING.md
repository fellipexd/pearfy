# Authoring Skills and references

## Canonical location and format

Store a module Skill at `.agents/skills/pearfy-<module>/SKILL.md`; put versioned details in that directory's `references/`. OpenCode receives a project-local symlink adapter under `.opencode/skills/`; do not maintain a second copy of Skill text in client configuration.

Frontmatter uses the Agent Skills-compatible `name` and `description` plus Pearfy metadata:

```yaml
---
name: pearfy-data
description: Use for typed SQL, schema IR, and migration planning.
metadata:
  pearfy-module: data
  pearfy-skill-version: 1.0.0
---
```

Keep the main guide focused on task selection: scope, prerequisites, commands for checking installed version, implemented capabilities, dependencies, security constraints, references and validation. Roughly 300–800 tokens is a target when sufficient, not a reason to delete mandatory safety rules.

## Reference rules

- Load a reference only when its topic is part of the active implementation.
- Link to version-controlled contracts/tests and concise explanations; do not paste the entire roadmap into a Skill.
- Treat source and tests as factual. A roadmap/example does not make a public Swift symbol or CLI command available.
- Split different capabilities into separate Skills when they have different prerequisites or are often used independently.
- Integration recipes belong in `.agents/recipes/`, state their availability, and link only to participating Skills.
- Planned Registry entries use `skill: null`; do not write a pretend API Skill for a planned module.

## Versioning and validation

Increment `pearfy-skill-version` for contract/behavior changes and update the module Registry's `skillVersion` together. The Registry module version is `workspace` when the product has no released SwiftPM version; use SDK milestone metadata only for capabilities that actually map to that milestone. Validate with `pearfy ai doctor`, `bash scripts/test-unit.sh`, and `pearfy guardian verify`.

# Migrating existing Pearfy projects

1. Run `pearfy modules doctor` when `.pearfy/modules.json` exists. Fix package drift before AI synchronization.
2. Run `pearfy ai inspect` to see inferred/locked modules, versions, Skill availability and planned modules.
3. Run `pearfy ai init --client opencode` (or `pearfy ai init` for a client-neutral Skills setup).
4. Review changes to `AGENTS.md`, `.pearfy/ai.json`, `.pearfy/ai-skills.lock.json`, `.agents/skills/`, `.agents/agents/`, `.opencode/` and `opencode.json`.
5. Run `pearfy ai doctor`, then the project build/tests and `pearfy guardian verify`.

## Legacy Populate sync

Older `pearfy ai sync` copied one `pearfy-populate/SKILL.md` without a file lock. If the existing file matches the current canonical Skill, sync records it. If it differs, sync preserves it and reports a conflict because the CLI cannot distinguish a local edit from a stale generated copy. Review the diff, back up any customization, then use `pearfy ai sync --force` only when replacing that file is intended.

## Legacy module lock

Version-1 `.pearfy/modules.json` is read compatibly. After validating the selected products, `pearfy ai sync` upgrades it to format 2 with the module Registry version map. A changed locked version is a drift error; resolve it intentionally before synchronization.

## Customization and removal

- Existing user text in `AGENTS.md` and non-Pearfy OpenCode settings are preserved.
- Skills changed since their last sync are never silently replaced. Untracked files inside a Skill directory are left alone.
- Adding/removing modules in a managed project reconciles only the selected module Skills. When a module is removed, unchanged files previously owned by Pearfy can be pruned; customized files remain as local orphans and are reported.
- `ai init` only manages OpenCode adapters in the project. It does not modify global config, global agents, API keys or unrelated MCP servers.
- A project with an existing custom `opencode.jsonc` requires a manual project-local MCP setting; the CLI reports INCOMPLETE instead of rewriting comments or formats.

The backend/package of an application remains untouched by `pearfy ai init`; this migration changes only the context/tooling layer.

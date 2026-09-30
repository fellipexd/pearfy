# Pearfy DevKit: Skills-first

Updated for Pearfy SDK capability milestones 1.6/1.7. Skills distribute static implementation knowledge; references provide deeper contracts on demand; CLI owns edits and inspection; MCP is reserved for project-enabled live operations; Guardian independently validates its declared gates.

## Context flow

1. Run `pearfy ai inspect` for a compact Registry summary and the current project's installed products.
2. Identify the modules touched by the requested behavior. Planned modules are listed, but not installable and have no usable Skill/API.
3. Read only `.agents/skills/<skill>/SKILL.md` for those modules.
4. Open only the reference named by the Skill when the implementation needs that contract. Inspect source/tests before using a symbol.
5. Use Pearfy CLI for planning, installation, inspection and validation. Enable MCP only for an operation requiring live data and only for an installed module that publishes tools.
6. Run relevant build/tests and `pearfy guardian verify`; unexecuted gates stay INCOMPLETE.

The Skill Registry maps actual Pearfy products to implementation state, installability, module/Skill versions, references, CLI commands, contracts, restrictions, configuration checks and validation commands. Runtime configuration and operational health cannot be inferred from package metadata; `pearfy ai inspect` reports those fields as `not-verified` until a real check exists.

## Project commands

```bash
pearfy ai init
pearfy ai init --client opencode
pearfy ai sync
pearfy ai inspect
pearfy ai inspect --module populate
pearfy ai inspect --scenarios
pearfy ai doctor
pearfy modules list
pearfy add social
pearfy ai mcp list
pearfy ai mcp enable populate
pearfy ai mcp disable populate
pearfy guardian verify
```

`pearfy add/remove` updates the managed SwiftPM product lock and synchronizes the corresponding installed Skills. Unmanaged Swift packages are inventoried from Pearfy product references; their package/module version remains unknown because no version lock exists. Legacy module lock v1 is upgraded to versioned format v2 by `pearfy ai sync` after `modules doctor` verifies it.

## Canonical files and preservation

- `.agents/skills/<skill>/` is the canonical, versioned Skills source.
- `.agents/agents/` contains small opt-in role prompts. Roles direct agents to Skills; they do not contain module manuals.
- `.agents/recipes/` contains cross-module recipes, each marked implemented/partial/planned.
- `.pearfy/ai.json` stores the client and explicitly enabled MCP module IDs. `.pearfy/ai-skills.lock.json` stores Skill/role versions and per-file SHA-256 baselines.
- OpenCode uses `.opencode/skills` and `.opencode/agents` symlink adapters into canonical `.agents` files. Project `opencode.json` disables Pearfy MCP by default. Global `~/.config/opencode` is not edited.
- `ai sync` installs only Skills matching installed products. Changed tracked files are reported and kept; `--force` is the explicit replacement path. Untracked files and unrelated configuration are preserved. Removing a module prunes only unchanged, previously managed Skill files.

If a project has a custom `opencode.jsonc`, Pearfy leaves it unchanged and `ai init`/`ai sync` reports the MCP overlay as INCOMPLETE; apply the documented project-local MCP setting manually after reviewing it. The CLI never rewrites global OpenCode configuration.

## MCP policy

Static project/module catalogs and plans belong to `pearfy ai inspect`/`pearfy modules`, not MCP. The MCP server advertises no Pearfy tools unless `.pearfy/ai.json` grants an installed module. This checkout currently publishes seven bounded Populate inspection/planning operations only; MCP has no database-write tool and accepts no approval tokens. No DevKit trace or metric MCP tools exist. Tools/list/resources/list are filtered to the installed, explicitly enabled modules.

MCP does not replace server authorization, Skills, CLI or Guardian. Do not add general shell execution as a substitute for specialized tools.

## OpenCode 1.18.32 adapter

The installed OpenCode CLI resolves project `opencode.json`, accepts the existing `mcp` object form (`type`, `command`, `enabled`, `timeout`) and discovers Skills under `.opencode/skills/<name>/SKILL.md`. `pearfy ai init --client opencode` installs relative symlinks to `.agents/skills` and `.agents/agents`, and merges only the Pearfy MCP entry into a project JSON config. It does not remove unrelated servers, agents, providers or plugins. Run `opencode debug skill` and `opencode debug config` to inspect the resolved project adapters; do not paste resolved provider credentials into issue reports or AI context.

## Guides

- [Writing a module Skill and references](AI-SKILLS-AUTHORING.md)
- [OpenCode setup and selective MCP](AI-OPENCODE.md)
- [Migrating existing projects](AI-HARNESS-MIGRATION.md)
- [Context measurements and limitations](AI-CONTEXT-MEASUREMENTS.md)
- [Guardian's actual gates](AI-GUARDIAN.md)

## Boundaries

`PearfyAI` is application runtime functionality and remains separate from development agents. Skills are short module-specific guides; no roadmap-only API is described as implemented. The DevKit UI retains its approved v1 white/green visual design; this change affects only AI knowledge distribution and CLI/MCP exposure.

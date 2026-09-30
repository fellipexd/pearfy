# OpenCode integration

The integration was checked against the installed OpenCode CLI **1.18.32**. The global configuration already contains custom providers, agents, plugins and MCP entries; Pearfy does not edit `~/.config/opencode`.

## Initialize

```bash
pearfy ai init --client opencode
```

This command:

- appends a small Pearfy-managed block to `AGENTS.md` without replacing existing text;
- installs Skills only for the products selected in `.pearfy/modules.json` (or infers referenced Pearfy products for unmanaged packages);
- creates `.opencode/skills/<skill>` links into `.agents/skills/<skill>` and `.opencode/agents/<role>.md` links into `.agents/agents/`;
- adds/merges a project-local `opencode.json` Pearfy MCP entry with `enabled: false` by default;
- leaves non-Pearfy MCP servers, providers, agents and plugins intact.

If a project-owned `opencode.jsonc` is present, the CLI does not rewrite it because JSONC comments/custom formatting cannot be safely preserved with the standard-library JSON writer. The Skills still synchronize, but `ai init` reports the MCP overlay as INCOMPLETE until the user sets the project-local Pearfy server `enabled` field intentionally.

## MCP on demand

```bash
pearfy ai mcp list
pearfy ai mcp enable populate
pearfy ai mcp disable populate
```

The allowlist is in `.pearfy/ai.json`; the project-local OpenCode setting is enabled only while an installed module with actual MCP tools is granted. Disabling removes the tool definitions on the next `tools/list`; it does not disable global OpenCode plugins or other MCP servers.

The current OpenCode config shape uses `mcp.<name>.type = "local"`, `command`, `enabled`, and optional `timeout`, matching the inspected 1.18.32 configuration. Pearfy does not add a broad shell tool. The only current Pearfy MCP tool family is bounded Populate inspection/planning; database writes and approval tokens remain in the direct local CLI.

## Inspect adapters

Run `opencode debug skill` to see discovered Skills and `opencode debug config` to inspect resolved settings locally. Resolved config may contain provider credentials; do not copy it into logs, tickets or model context. Use `pearfy ai doctor` for Pearfy project adapter checks.

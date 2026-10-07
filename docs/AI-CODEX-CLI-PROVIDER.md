# PearfyAI Codex CLI provider

`CodexCLIProvider` adapts the official local `codex exec` command to PearfyAI's `AIProvider` contract. It uses Codex's own ChatGPT sign-in, token refresh and subscription enforcement; Pearfy does not implement the private OAuth exchange or Codex backend protocol, read token files, or forward OAuth credentials.

## Sign in and verify

Install the official Codex CLI, then sign in as the operating-system account that runs EmberSquare/Pearfy:

```sh
codex login
codex login status
```

The provider runs a headless ephemeral session with the configured model and the official `--output-schema` option. It reads prompt data only from stdin, stores its schema and last response in a private temporary directory, runs in an empty directory with a read-only sandbox, ignores user config/rules, and sends stdout/stderr to null. It filters API-key environment variables so `OPENAI_API_KEY` cannot silently select a metered API account. `CODEX_HOME` and `HOME` are retained so the CLI can use its own login.

## Pearfy use

```swift
let provider = try CodexCLIProvider(
    executableURL: nil, // resolves `codex` from PATH
    timeout: .seconds(90),
    codexHome: nil // uses CODEX_HOME or the current user's default
)
let response = try await provider.complete(
    model: "gpt-5-codex",
    messages: [AIChatMessage(role: .user, content: "Return the requested JSON result")],
    temperature: 0,
    maximumTokens: 500
)
```

Configure EmberSquare with `PEARFY_AI_PRIMARY_PROVIDER=codex_cli`, `PEARFY_AI_PRIMARY_MODEL=<model supported by codex>`, and optionally `PEARFY_CODEX_EXECUTABLE`, `PEARFY_CODEX_HOME`, `PEARFY_CODEX_TIMEOUT_SECONDS`. This is useful for a single-user/local service or a deliberately provisioned worker running under that signed-in account. The app must have Codex installed and access to the intended `CODEX_HOME`.

`CodexCLIProvider` accepts an optional reasoning-effort override (`minimal`, `low`, `medium`, `high` or `xhigh`) and maps it to Codex's `model_reasoning_effort` CLI configuration. Pearfy does not invent or discover model IDs; the caller supplies the ID that its installed Codex CLI supports.

## Quota and deployment

Requests are made by Codex CLI under the logged-in account's ChatGPT/Codex entitlement, not with an OpenAI Platform API key. Usage is subject to the account's plan, current quotas, model availability and OpenAI policies; the adapter does not increase or bypass those limits. If Codex is unavailable or quota-limited, provider errors reach PearfySocial's normal durable retry and fail-safe `REVIEW` path. A metered API provider is used only if an operator explicitly configures it as a fallback.

Do not share one individual's subscription account as an unapproved multi-user service. Production deployments should use an entitlement and usage pattern permitted for the organization. The subprocess does not receive user post data as command arguments, but the Codex service necessarily receives the prompt content through stdin. Codex tool use is discouraged in the prompt; the process also runs in an empty temp directory with the CLI read-only sandbox and no user/project instructions. Never change this adapter to call undocumented Codex endpoints or manually replay OAuth tokens.

The generic `AIProvider` method accepts temperature/token-budget hints for compatibility; Codex CLI controls those according to its own model/runtime rather than exposing all chat-completions parameters.

# Application AI reference

- Current implementation is a chat client in `Sources/PearfyAI/OpenAICompatibleClient.swift`, depending on `PearfyCloud`.
- It is runtime functionality for the application. Do not use it to configure coding agents, OpenCode, Skills or MCP.
- Provider response errors are sanitized; keep secrets in backend configuration and prevent bodies/credentials from entering metrics or logs.
- The product does not currently supply a chatbot orchestrator, CRM agent, vector database, tool registry or autonomous agent runtime.
- Tests use a controlled transport; no real provider is required for unit verification.

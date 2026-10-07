# Application AI reference

- OpenAI-compatible chat lives in `Sources/PearfyAI/OpenAICompatibleClient.swift`; embeddings are in `Sources/PearfyAI/Embeddings.swift`, both using `PearfyCloud`.
- `CodexCLIProvider` invokes the official `codex exec` command with schema-constrained output, an ephemeral session and read-only sandbox. It passes prompt data on stdin, removes API-key variables from the child environment and leaves OAuth/token refresh to Codex CLI. The caller's Codex account/plan governs quota.
- `AIWorkflow`, `RAGRetriever`, `RAGFilter`, `RAGChunk` and `StructuredAIOutput` are contracts in `Sources/PearfyAI/Workflow.swift`, not an implementation of LangGraph or a vector store.
- `JevDecisionClient` implements the typed Jev choice primitive in `Sources/PearfyAI/JevDecisionClient.swift`; it returns an allowlisted choice and confidence rather than generated prose. It is used by the optional `PearfyGameServerNPCLearn` module.
- This is application runtime functionality. Do not use it to configure OpenCode, Skills or MCP.
- Provider response errors are sanitized; keep secrets in backend configuration and prevent bodies/credentials from entering metrics or logs.
- The product does not supply a LangGraph runtime, vector database, tool registry or autonomous agent runtime. `CodexCLIProvider` is a subscription-backed CLI bridge and should run only under a deliberately provisioned worker account.
- Tests use a controlled transport; no real provider is required for unit verification.

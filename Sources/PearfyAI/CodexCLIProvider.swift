import Foundation

/// Uses the official Codex CLI's existing sign-in and entitlement. No OAuth
/// tokens are read, copied, or sent by Pearfy; the CLI owns authentication and
/// applies the active ChatGPT/Codex account's quota and policy.
public struct CodexCLIProvider: AIProvider, Sendable {
    private let executableURL: URL?
    private let timeoutMilliseconds: Int
    private let codexHome: URL?
    private let outputSchema: Data?
    private let reasoningEffort: String?

    public init(
        executableURL: URL? = nil,
        timeout: Duration = .seconds(90),
        codexHome: URL? = nil,
        outputSchema: Data? = nil,
        reasoningEffort: String? = nil
    ) throws {
        guard timeout > .zero, timeout <= .seconds(3_600) else {
            throw AIProviderError.invalidConfiguration("Codex command timeout must be in 1...3600 seconds")
        }
        if let reasoningEffort,
           !["minimal", "low", "medium", "high", "xhigh"].contains(reasoningEffort.lowercased()) {
            throw AIProviderError.invalidConfiguration("unsupported Codex reasoning effort")
        }
        let components = timeout.components
        let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        self.executableURL = executableURL
        self.timeoutMilliseconds = Int(milliseconds)
        self.codexHome = codexHome
        self.outputSchema = outputSchema
        self.reasoningEffort = reasoningEffort?.lowercased()
    }

    public func complete(
        model: String,
        messages: [AIChatMessage],
        temperature: Double?,
        maximumTokens: Int?
    ) async throws -> AIChatResponse {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !messages.isEmpty,
              messages.reduce(0, { $0 + $1.content.utf8.count }) <= 100_000 else {
            throw AIProviderError.invalidRequest("Codex model and bounded messages are required")
        }
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Self.run(
                executableURL: executableURL,
                codexHome: codexHome,
                timeoutMilliseconds: timeoutMilliseconds,
                model: model,
                messages: messages,
                outputSchema: outputSchema,
                reasoningEffort: reasoningEffort
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func run(
        executableURL: URL?,
        codexHome: URL?,
        timeoutMilliseconds: Int,
        model: String,
        messages: [AIChatMessage],
        outputSchema: Data?,
        reasoningEffort: String?
    ) throws -> AIChatResponse {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pearfy-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("response.json")
        let schemaURL: URL?
        if let outputSchema {
            let url = directory.appendingPathComponent("structured-output.schema.json")
            try outputSchema.write(to: url, options: .atomic)
            schemaURL = url
        } else {
            schemaURL = nil
        }

        let process = Process()
        if let executableURL {
            process.executableURL = executableURL
            process.arguments = arguments(model: model, schemaURL: schemaURL, outputURL: outputURL, reasoningEffort: reasoningEffort)
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["codex"] + arguments(model: model, schemaURL: schemaURL, outputURL: outputURL, reasoningEffort: reasoningEffort)
        }
        process.currentDirectoryURL = directory
        process.environment = sanitizedEnvironment(codexHome: codexHome)
        let inputPipe = Pipe()
        let standardErrorURL = directory.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let standardErrorHandle = try FileHandle(forWritingTo: standardErrorURL)
        defer { try? standardErrorHandle.close() }
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardErrorHandle

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
            let prompt = renderPrompt(messages)
            try inputPipe.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
            try inputPipe.fileHandleForWriting.close()
        } catch {
            if process.isRunning { process.terminate() }
            throw AIProviderError.invalidConfiguration("could not start the Codex CLI")
        }

        let timeout = DispatchTime.now() + .milliseconds(timeoutMilliseconds)
        var completed = false
        while DispatchTime.now() < timeout {
            if Task.isCancelled {
                if process.isRunning { process.terminate() }
                _ = exited.wait(timeout: .now() + .seconds(2))
                throw CancellationError()
            }
            if exited.wait(timeout: .now() + .milliseconds(100)) == .success {
                completed = true
                break
            }
        }
        guard completed else {
            if process.isRunning { process.terminate() }
            _ = exited.wait(timeout: .now() + .seconds(2))
            throw AIProviderError.commandTimeout
        }
        try? standardErrorHandle.close()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            if ProcessInfo.processInfo.environment["PEARFY_CODEX_DIAGNOSTICS"] == "true" {
                let data = (try? Data(contentsOf: standardErrorURL)) ?? Data()
                let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                    .map(String.init)
                    .filter { line in
                        let value = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        return value.hasPrefix("error:") || value.hasPrefix("fatal:")
                            || value.contains("authentication failed") || value.contains("quota exceeded")
                            || value.contains("invalid model")
                    }
                    .map { String($0.prefix(300)) }
                if !lines.isEmpty {
                    FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
                }
            }
            throw AIProviderError.commandFailed(process.terminationStatus)
        }
        let response = try Data(contentsOf: outputURL)
        guard !response.isEmpty, let content = String(data: response, encoding: .utf8) else {
            throw AIProviderError.invalidResponse("Codex CLI returned no UTF-8 response")
        }
        return AIChatResponse(content: content, model: model)
    }

    private static func arguments(model: String, schemaURL: URL?, outputURL: URL, reasoningEffort: String?) -> [String] {
        var values = [
            "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check",
            "--sandbox", "read-only",
            "--disable", "shell_tool", "--disable", "browser_use", "--disable", "browser_use_external",
            "--disable", "browser_use_full_cdp_access", "--disable", "computer_use", "--disable", "apps",
            "--disable", "hooks", "--disable", "plugins", "--disable", "unified_exec",
            "--disable", "unified_exec_tty", "--disable", "code_mode_host", "--disable", "code_mode",
            "--disable", "enable_mcp_apps", "--disable", "tool_call_mcp_elicitation"
        ]
        if let reasoningEffort { values += ["-c", "model_reasoning_effort=\(reasoningEffort)"] }
        if let schemaURL { values += ["--output-schema", schemaURL.path] }
        values += ["--output-last-message", outputURL.path, "--model", model, "-"]
        return values
    }

    private static func sanitizedEnvironment(codexHome: URL?) -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let allowed = ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "CODEX_HOME"]
        var result = Dictionary(uniqueKeysWithValues: allowed.compactMap { key in source[key].map { (key, $0) } })
        if let codexHome { result["CODEX_HOME"] = codexHome.path }
        // Deliberately omit OPENAI_API_KEY and other API-key variables so the CLI
        // cannot silently switch from subscription OAuth to metered API billing.
        return result
    }

    private static func renderPrompt(_ messages: [AIChatMessage]) -> String {
        var sections = ["You are running in moderation-only mode. Do not inspect files, run commands, invoke tools, or take actions. Return only the requested structured classification."]
        for message in messages {
            switch message.role {
            case .system:
                sections.append("<SYSTEM_INSTRUCTIONS>\n\(message.content)\n</SYSTEM_INSTRUCTIONS>")
            case .user:
                let value = (try? JSONEncoder().encode(message.content)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
                sections.append("<UNTRUSTED_USER_CONTENT_JSON>\n\(value)\n</UNTRUSTED_USER_CONTENT_JSON>")
            case .assistant:
                let value = (try? JSONEncoder().encode(message.content)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
                sections.append("<UNTRUSTED_PRIOR_OUTPUT_JSON>\n\(value)\n</UNTRUSTED_PRIOR_OUTPUT_JSON>")
            }
        }
        return sections.joined(separator: "\n\n")
    }

}

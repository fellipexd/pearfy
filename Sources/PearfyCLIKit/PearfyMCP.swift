import Foundation

/// Runs the Pearfy read-only MCP server over the standard-I/O transport.
public enum PearfyMCPCommand {
    public static func run(projectRoot: URL) throws -> Int32 {
        let handler = PearfyMCPRequestHandler(projectRoot: projectRoot.standardizedFileURL.resolvingSymlinksInPath())
        while let line = readLine() {
            guard line.utf8.count <= PearfyMCPRequestHandler.maximumMessageBytes else {
                let response = PearfyMCPRequestHandler.errorResponse(
                    id: NSNull(),
                    code: -32600,
                    message: "MCP message exceeds the 1 MiB limit"
                )
                try write(response)
                continue
            }
            if let response = handler.handle(line: line) { try write(response) }
        }
        return 0
    }

    private static func write(_ response: String) throws {
        try FileHandle.standardOutput.write(contentsOf: Data((response + "\n").utf8))
    }
}

struct PearfyMCPRequestHandler {
    static let maximumMessageBytes = 1_048_576

    let projectRoot: URL

    func handle(line: String) -> String? {
        let request: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                return Self.errorResponse(id: NSNull(), code: -32600, message: "MCP request must be a JSON object")
            }
            request = object
        } catch {
            return Self.errorResponse(id: NSNull(), code: -32700, message: "Invalid JSON")
        }

        guard request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else {
            guard let id = request["id"] else { return nil }
            return Self.errorResponse(id: id, code: -32600, message: "Invalid JSON-RPC request")
        }
        guard let id = request["id"] else { return nil }

        do {
            let result = try dispatch(method: method, params: request["params"] as? [String: Any] ?? [:])
            return Self.response(id: id, result: result)
        } catch let error as PearfyMCPProtocolError {
            return Self.errorResponse(id: id, code: error.code, message: error.message)
        } catch {
            return Self.errorResponse(id: id, code: -32603, message: "Internal Pearfy MCP error: \(error)")
        }
    }

    private func dispatch(method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            let requestedVersion = params["protocolVersion"] as? String
            let supportedVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]
            return [
                "protocolVersion": requestedVersion.flatMap { supportedVersions.contains($0) ? $0 : nil } ?? "2025-03-26",
                "capabilities": [
                    "tools": ["listChanged": false],
                    "resources": ["subscribe": false, "listChanged": false]
                ],
                "serverInfo": ["name": "pearfy", "version": "0.1.0"],
                "instructions": "Pearfy Skills and CLI are the primary source for static knowledge and edits. Project-enabled Populate MCP tools may inspect data or create bounded local plans, but cannot write to the database. Database writes and approval tokens stay in the local CLI, never MCP arguments."
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": try toolsForEnabledModules()]
        case "tools/call":
            return try callTool(params)
        case "resources/list":
            return ["resources": try resourcesForEnabledModules()]
        case "resources/templates/list":
            return ["resourceTemplates": try resourceTemplatesForEnabledModules()]
        case "resources/read":
            return try readResource(params)
        default:
            throw PearfyMCPProtocolError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private func callTool(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else {
            throw PearfyMCPProtocolError(code: -32602, message: "tools/call requires a tool name")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            guard let moduleID = Self.moduleID(forTool: name) else {
                return [
                    "content": [["type": "text", "text": "Unknown Pearfy MCP tool: \(name). Use the Pearfy CLI or its installed module Skill for static information."]],
                    "isError": true
                ]
            }
            let registryModule = try PearfyModuleManager().module(named: moduleID)
            guard registryModule.available, registryModule.mcpTools.contains(name),
                  try enabledMCPModules().contains(moduleID) else {
                return [
                    "content": [["type": "text", "text": "MCP tools for module '\(moduleID)' are disabled or the module is not installed. Use `pearfy ai mcp enable \(moduleID)` only for a task that needs live data."]],
                    "isError": true
                ]
            }
            let output: Any
            switch name {
            case "pearfy.populate.inspect":
                let environment = try populateEnvironment(in: arguments)
                output = try populateCommand(["inspect", "--environment", environment])
            case "pearfy.populate.profile":
                let environment = try populateEnvironment(in: arguments)
                guard environment == "local" else {
                    throw PearfyMCPProtocolError(code: -32602, message: "populate profile is limited to local environments")
                }
                let table = try requiredString("table", in: arguments)
                output = try populateCommand(["profile", "--table", table, "--environment", "local", "--sample-local"])
            case "pearfy.populate.plan":
                output = try populatePlan(arguments)
            case "pearfy.populate.preview":
                let planID = try requiredSafeID("planID", in: arguments)
                let path = projectRoot.appendingPathComponent(".pearfy/populate/plans/\(planID).json").path
                output = try populateCommand(["preview", "--plan", path])
            case "pearfy.populate.status":
                let runID = try requiredSafeID("runID", in: arguments)
                output = try populateCommand(["status", "--run", runID])
            case "pearfy.populate.verify":
                let environment = try populateEnvironment(in: arguments)
                let runID = try requiredSafeID("runID", in: arguments)
                output = try populateCommand(["verify", "--run", runID, "--environment", environment])
            case "pearfy.populate.report":
                let runID = try requiredSafeID("runID", in: arguments)
                output = try populateCommand(["report", "--run", runID])
            default:
                return [
                    "content": [["type": "text", "text": "Unknown Pearfy MCP tool: \(name)"]],
                    "isError": true
                ]
            }
            let text: String
            if let output = output as? String { text = output }
            else { text = try Self.jsonText(output) }
            return ["content": [["type": "text", "text": text]]]
        } catch let error as PearfyMCPProtocolError {
            return [
                "content": [["type": "text", "text": error.message]],
                "isError": true
            ]
        } catch {
            return [
                "content": [["type": "text", "text": String(describing: error)]],
                "isError": true
            ]
        }
    }

    private func readResource(_ params: [String: Any]) throws -> [String: Any] {
        guard let uri = params["uri"] as? String else {
            throw PearfyMCPProtocolError(code: -32602, message: "resources/read requires a URI")
        }
        guard try isDeclaredResource(uri) else {
            throw PearfyMCPProtocolError(code: -32602, message: "Unknown or disabled Pearfy MCP resource: \(uri)")
        }
        let content: Any
        if uri == "pearfy://populate/schema" {
            try requireEnabledMCPModule("populate")
            content = try populateCommand(["inspect", "--environment", "local"])
        } else if uri.hasPrefix("pearfy://populate/plans/") {
            try requireEnabledMCPModule("populate")
            let id = String(uri.dropFirst("pearfy://populate/plans/".count))
            guard Self.isSafePopulateID(id) else { throw PearfyMCPProtocolError(code: -32602, message: "Invalid populate plan URI") }
            let path = projectRoot.appendingPathComponent(".pearfy/populate/plans/\(id).json").path
            content = try populateCommand(["preview", "--plan", path])
        } else if uri.hasPrefix("pearfy://populate/runs/") {
            try requireEnabledMCPModule("populate")
            let id = String(uri.dropFirst("pearfy://populate/runs/".count))
            guard Self.isSafePopulateID(id) else { throw PearfyMCPProtocolError(code: -32602, message: "Invalid populate run URI") }
            content = try populateCommand(["status", "--run", id])
        } else if uri.hasPrefix("pearfy://populate/profiles/") {
            try requireEnabledMCPModule("populate")
            let table = String(uri.dropFirst("pearfy://populate/profiles/".count))
            guard !table.isEmpty, !table.contains("/") else { throw PearfyMCPProtocolError(code: -32602, message: "Invalid populate profile URI") }
            content = try populateCommand(["profile", "--table", table, "--environment", "local", "--sample-local"])
        } else {
            throw PearfyMCPProtocolError(code: -32602, message: "Unknown Pearfy MCP resource: \(uri)")
        }
        let text: String
        if let rawText = content as? String { text = rawText }
        else { text = try Self.jsonText(content) }
        return ["contents": [[
            "uri": uri,
            "mimeType": "application/json",
            "text": text
        ]]]
    }

    private func toolsForEnabledModules() throws -> [[String: Any]] {
        let enabled = try enabledMCPModules()
        let allowedTools = Set(try PearfyModuleManager().catalogModules()
            .filter { enabled.contains($0.id) && $0.available }
            .flatMap(\.mcpTools))
        return Self.tools.filter { tool in
            guard let name = tool["name"] as? String,
                  Self.moduleID(forTool: name) != nil else { return false }
            return allowedTools.contains(name)
        }
    }

    private func resourcesForEnabledModules() throws -> [[String: Any]] {
        let enabled = try enabledMCPModules()
        let allowed = Set(try PearfyModuleManager().catalogModules()
            .filter { enabled.contains($0.id) && $0.available }
            .flatMap(\.mcpResources))
        return Self.resources.filter { allowed.contains($0["uri"] as? String ?? "") }
    }

    private func resourceTemplatesForEnabledModules() throws -> [[String: Any]] {
        let enabled = try enabledMCPModules()
        let allowed = Set(try PearfyModuleManager().catalogModules()
            .filter { enabled.contains($0.id) && $0.available }
            .flatMap(\.mcpResourceTemplates))
        return Self.resourceTemplates.filter { allowed.contains($0["uriTemplate"] as? String ?? "") }
    }

    private func isDeclaredResource(_ uri: String) throws -> Bool {
        let enabled = try enabledMCPModules()
        let manifests = try PearfyModuleManager().catalogModules().filter { enabled.contains($0.id) && $0.available }
        if manifests.contains(where: { $0.mcpResources.contains(uri) }) { return true }
        return manifests.contains { module in
            module.mcpResourceTemplates.contains { template in
                let prefix = template.components(separatedBy: "{").first ?? template
                return uri.hasPrefix(prefix) && uri.count > prefix.count && !uri.dropFirst(prefix.count).contains("/")
            }
        }
    }

    private func enabledMCPModules() throws -> Set<String> {
        let settings = PearfyAIProjectState.settings(at: projectRoot)
        guard settings.valid else {
            throw PearfyMCPProtocolError(code: -32002, message: "Pearfy AI module grants are missing or invalid; run `pearfy ai doctor`")
        }
        let manager = try PearfyModuleManager()
        let installed = Set(try PearfyAIProjectState.inspectModules(projectRoot: projectRoot, manager: manager).installed)
        return settings.mcpModules.intersection(installed)
    }

    private func requireEnabledMCPModule(_ moduleID: String) throws {
        guard try enabledMCPModules().contains(moduleID) else {
            throw PearfyMCPProtocolError(code: -32002, message: "MCP tools for '\(moduleID)' are disabled or the module is not installed")
        }
    }

    private static func moduleID(forTool name: String) -> String? {
        name.hasPrefix("pearfy.populate.") ? "populate" : nil
    }

    private func requiredString(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else {
            throw PearfyMCPProtocolError(code: -32602, message: "Missing string argument '\(key)'")
        }
        return value
    }

    private func requiredSafeID(_ key: String, in arguments: [String: Any]) throws -> String {
        let value = try requiredString(key, in: arguments)
        guard Self.isSafePopulateID(value) else {
            throw PearfyMCPProtocolError(code: -32602, message: "Invalid \(key)")
        }
        return value
    }

    private func populateEnvironment(in arguments: [String: Any]) throws -> String {
        let value = try requiredString("environment", in: arguments)
        guard value == "local" || value == "staging" else {
            throw PearfyMCPProtocolError(code: -32602, message: "environment must be local or staging")
        }
        return value
    }

    private func populatePlan(_ arguments: [String: Any]) throws -> String {
        let environment = try populateEnvironment(in: arguments)
        var command = ["plan", "--environment", environment, "--table", try requiredString("table", in: arguments)]
        if let rows = arguments["rows"] as? NSNumber {
            guard rows.intValue > 0, rows.intValue <= 100_000 else {
                throw PearfyMCPProtocolError(code: -32602, message: "rows must be between 1 and 100000")
            }
            command += ["--rows", rows.stringValue]
        } else if let targetSize = arguments["targetSize"] as? String {
            command += ["--target-size", targetSize, "--size-mode", try requiredString("sizeMode", in: arguments)]
        } else {
            throw PearfyMCPProtocolError(code: -32602, message: "provide rows or targetSize")
        }
        if let seed = arguments["seed"] as? NSNumber { command += ["--seed", seed.stringValue] }
        return try populateCommand(command)
    }

    private func populateCommand(_ arguments: [String], input: String? = nil) throws -> String {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let process = Process()
        process.executableURL = executable
        process.arguments = ["populate"] + arguments
        process.currentDirectoryURL = projectRoot
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let inputPipe = input.map { _ in Pipe() }
        if let inputPipe { process.standardInput = inputPipe }
        else { process.standardInput = FileHandle.nullDevice }
        try process.run()
        if let input, let inputPipe {
            try inputPipe.fileHandleForWriting.write(contentsOf: Data((input + "\n").utf8))
            try inputPipe.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PearfyMCPProtocolError(code: -32603, message: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard data.count <= Self.maximumMessageBytes else {
            throw PearfyMCPProtocolError(code: -32603, message: "populate tool response exceeds the 1 MiB limit")
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil else {
            throw PearfyMCPProtocolError(code: -32603, message: "populate command returned invalid JSON")
        }
        return text
    }

    private static func isSafePopulateID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...122).contains($0) || $0 == 45
        }
    }

    static var tools: [[String: Any]] {
        return [
            [
                "name": "pearfy.populate.inspect",
                "description": "Inspect the local/staging PostgreSQL schema and migration state; does not return table rows.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["environment": ["type": "string", "enum": ["local", "staging"]]],
                    "required": ["environment"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "pearfy.populate.profile",
                "description": "Return aggregate-only statistics from a read-only local PostgreSQL transaction.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "environment": ["type": "string", "enum": ["local"]],
                        "table": ["type": "string", "minLength": 1]
                    ],
                    "required": ["environment", "table"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "pearfy.populate.plan",
                "description": "Create a bounded local plan; database rows are not returned and execution is not started.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "environment": ["type": "string", "enum": ["local", "staging"]],
                        "table": ["type": "string", "minLength": 1],
                        "rows": ["type": "integer", "minimum": 1, "maximum": 100000],
                        "seed": ["type": "integer", "minimum": 0],
                        "targetSize": ["type": "string"],
                        "sizeMode": ["type": "string", "enum": ["total", "table", "heap"]]
                    ],
                    "required": ["environment", "table"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "pearfy.populate.preview",
                "description": "Preview a previously generated plan by ID; read-only.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["planID": ["type": "string", "minLength": 1]],
                    "required": ["planID"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "pearfy.populate.status",
                "description": "Read a local populate run checkpoint.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["runID": ["type": "string", "minLength": 1]],
                    "required": ["runID"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "pearfy.populate.verify",
                "description": "Verify measured size and schema state for an existing run; read-only.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "environment": ["type": "string", "enum": ["local", "staging"]],
                        "runID": ["type": "string", "minLength": 1]
                    ],
                    "required": ["environment", "runID"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "pearfy.populate.report",
                "description": "Read the aggregate report for a populate run.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["runID": ["type": "string", "minLength": 1]],
                    "required": ["runID"],
                    "additionalProperties": false
                ]
            ]
        ]
    }

    static var resources: [[String: Any]] {
        return [[
                "uri": "pearfy://populate/schema",
                "name": "populate-schema",
                "description": "Filtered PostgreSQL schema and migration metadata without row values.",
                "mimeType": "application/json"
            ]]
    }

    static var resourceTemplates: [[String: Any]] {
        return [[
                "uriTemplate": "pearfy://populate/plans/{id}",
                "name": "populate-plan",
                "description": "A saved populate plan by ID.",
                "mimeType": "application/json"
            ], [
                "uriTemplate": "pearfy://populate/runs/{id}",
                "name": "populate-run",
                "description": "A local run checkpoint by ID.",
                "mimeType": "application/json"
            ], [
                "uriTemplate": "pearfy://populate/profiles/{table}",
                "name": "populate-profile",
                "description": "Aggregate-only local database profile for a table.",
                "mimeType": "application/json"
            ]]
    }

    private static func response(id: Any, result: [String: Any]) -> String {
        jsonString(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func errorResponse(id: Any, code: Int, message: String) -> String {
        jsonString(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func jsonText(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonString(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Unable to serialize MCP response"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct PearfyMCPProtocolError: Error {
    let code: Int
    let message: String
}

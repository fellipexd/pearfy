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
                "instructions": "Read-only Pearfy project and module inspection. Module plans never modify the workspace."
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": Self.tools]
        case "tools/call":
            return try callTool(params)
        case "resources/list":
            return ["resources": Self.resources]
        case "resources/templates/list":
            return ["resourceTemplates": Self.resourceTemplates]
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
            let output: Any
            switch name {
            case "pearfy.project.inspect":
                output = try inspectProject()
            case "pearfy.modules.list":
                output = try listModules()
            case "pearfy.modules.inspect":
                let moduleID = try requiredString("module", in: arguments)
                output = try inspectModule(moduleID)
            case "pearfy.modules.plan":
                let action = try requiredString("action", in: arguments)
                let moduleID = try requiredString("module", in: arguments)
                output = try planModule(action: action, moduleID: moduleID)
            default:
                return [
                    "content": [["type": "text", "text": "Unknown Pearfy MCP tool: \(name)"]],
                    "isError": true
                ]
            }
            return ["content": [["type": "text", "text": try Self.jsonText(output)]]]
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
        let content: Any
        if uri == "pearfy://project/context" {
            content = try inspectProject()
        } else if uri == "pearfy://modules" {
            content = try listModules()
        } else if uri.hasPrefix("pearfy://modules/") {
            let moduleID = String(uri.dropFirst("pearfy://modules/".count))
            guard !moduleID.isEmpty, !moduleID.contains("/") else {
                throw PearfyMCPProtocolError(code: -32602, message: "Invalid module resource URI")
            }
            content = try inspectModule(moduleID)
        } else {
            throw PearfyMCPProtocolError(code: -32602, message: "Unknown Pearfy MCP resource: \(uri)")
        }
        return ["contents": [[
            "uri": uri,
            "mimeType": "application/json",
            "text": try Self.jsonText(content)
        ]]]
    }

    private func inspectProject() throws -> [String: Any] {
        let packageURL = projectRoot.appendingPathComponent("Package.swift")
        let lockURL = projectRoot.appendingPathComponent(".pearfy/modules.json")
        let isManaged = FileManager.default.fileExists(atPath: lockURL.path)
        var selectedModules: [String]?
        var moduleConfigurationError: String?
        if isManaged {
            do {
                selectedModules = try PearfyModuleManager().doctor(projectRoot: projectRoot)
            } catch {
                moduleConfigurationError = String(describing: error)
            }
        }
        var result: [String: Any] = [
            "workspacePath": projectRoot.path,
            "swiftPackage": FileManager.default.fileExists(atPath: packageURL.path),
            "pearfyManaged": isManaged
        ]
        if let selectedModules { result["selectedModules"] = selectedModules }
        if let moduleConfigurationError { result["moduleConfigurationError"] = moduleConfigurationError }
        return result
    }

    private func listModules() throws -> [[String: Any]] {
        try PearfyModuleManager().availableModules().map { module in
            [
                "id": module.id,
                "summary": module.summary,
                "requires": module.requirements.sorted(),
                "products": module.products.sorted()
            ]
        }
    }

    private func inspectModule(_ id: String) throws -> [String: Any] {
        let module = try PearfyModuleManager().module(named: id)
        return [
            "id": module.id,
            "summary": module.summary,
            "requires": module.requirements.sorted(),
            "products": module.products.sorted()
        ]
    }

    private func planModule(action: String, moduleID: String) throws -> [String: Any] {
        let manager = try PearfyModuleManager()
        let selected = try manager.doctor(projectRoot: projectRoot)
        let plan: PearfyModulePlan
        switch action {
        case "add": plan = try manager.planAdding(moduleID, to: selected)
        case "remove": plan = try manager.planRemoving(moduleID, from: selected)
        default: throw PearfyMCPProtocolError(code: -32602, message: "action must be 'add' or 'remove'")
        }
        return [
            "action": plan.action,
            "module": plan.module,
            "currentModules": plan.currentModules,
            "plannedModules": plan.plannedModules,
            "productsToAdd": plan.productsToAdd,
            "productsToRemove": plan.productsToRemove,
            "readOnly": true
        ]
    }

    private func requiredString(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else {
            throw PearfyMCPProtocolError(code: -32602, message: "Missing string argument '\(key)'")
        }
        return value
    }

    static var tools: [[String: Any]] {
        return [
            [
                "name": "pearfy.project.inspect",
                "description": "Inspect the current workspace for a Swift package and Pearfy module-manager metadata. Does not read source files or secrets.",
                "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false]
            ],
            [
                "name": "pearfy.modules.list",
                "description": "List Pearfy modules available in this installed framework checkout.",
                "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false]
            ],
            [
                "name": "pearfy.modules.inspect",
                "description": "Inspect one available Pearfy module and its product dependencies.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["module": ["type": "string", "description": "Pearfy module ID"]],
                    "required": ["module"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "pearfy.modules.plan",
                "description": "Preview adding or removing a Pearfy module in the current managed project. This tool never edits files.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["add", "remove"]],
                        "module": ["type": "string", "description": "Pearfy module ID"]
                    ],
                    "required": ["action", "module"],
                    "additionalProperties": false
                ]
            ]
        ]
    }

    static var resources: [[String: Any]] {
        return [
            [
                "uri": "pearfy://project/context",
                "name": "project-context",
                "description": "Current workspace and Pearfy module-manager status. Does not include source files or secrets.",
                "mimeType": "application/json"
            ],
            [
                "uri": "pearfy://modules",
                "name": "modules",
                "description": "Available Pearfy modules and their product dependencies.",
                "mimeType": "application/json"
            ]
        ]
    }

    static var resourceTemplates: [[String: Any]] {
        return [[
                "uriTemplate": "pearfy://modules/{id}",
                "name": "module-details",
                "description": "Details for one available Pearfy module.",
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

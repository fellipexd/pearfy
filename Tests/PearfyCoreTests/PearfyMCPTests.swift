import Foundation
@testable import PearfyCLIKit
import Testing

@Test func pearfyMCPDefaultsToNoToolsAndRequiresInstalledModuleGrantForPopulateTools() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-mcp-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

    let frameworkRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let projectRoot = temporaryRoot.appendingPathComponent("mcp-api", isDirectory: true)
    _ = try ProjectScaffolder(frameworkRoot: frameworkRoot).createProject(named: "mcp-api", at: projectRoot)
    let handler = PearfyMCPRequestHandler(projectRoot: projectRoot)

    let initialize = try #require(responseObject(
        from: handler,
        id: 1,
        method: "initialize",
        params: ["protocolVersion": "2025-03-26"]
    )["result"] as? [String: Any])
    #expect(initialize["protocolVersion"] as? String == "2025-03-26")
    #expect((initialize["serverInfo"] as? [String: Any])?["name"] as? String == "pearfy")

    let tools = try #require((responseObject(from: handler, id: 2, method: "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    #expect(tools.isEmpty)

    let manifestURL = projectRoot.appendingPathComponent("Package.swift")
    let lockURL = projectRoot.appendingPathComponent(".pearfy/modules.json")
    let manager = try PearfyModuleManager()
    let installPlan = try manager.planAdding("populate", to: try manager.doctor(projectRoot: projectRoot))
    try manager.apply(installPlan, to: projectRoot)
    #expect(try PearfyAICommand.run(
        arguments: ["init", "--client", "opencode"],
        projectRoot: projectRoot,
        frameworkRoot: frameworkRoot
    ) == 0)

    let toolWhileDisabled = try responseObject(
        from: handler,
        id: 3,
        method: "tools/call",
        params: [
            "name": "pearfy.populate.inspect",
            "arguments": ["environment": "local"]
        ]
    )
    #expect((toolWhileDisabled["result"] as? [String: Any])?["isError"] as? Bool == true)

    #expect(try PearfyAICommand.run(arguments: ["mcp", "enable", "populate"], projectRoot: projectRoot, frameworkRoot: frameworkRoot) == 0)
    let enabledTools = try #require((responseObject(from: handler, id: 4, method: "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    #expect(Set(enabledTools.compactMap { $0["name"] as? String }) == [
        "pearfy.populate.inspect", "pearfy.populate.profile", "pearfy.populate.plan",
        "pearfy.populate.preview", "pearfy.populate.status", "pearfy.populate.verify", "pearfy.populate.report"
    ])
    #expect(enabledTools.allSatisfy { !($0["name"] as? String ?? "").hasSuffix(".run") })
    #expect(enabledTools.allSatisfy { tool in
        let properties = (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        return properties["approvalToken"] == nil
    })

    let removedWriteTool = try responseObject(
        from: handler,
        id: 7,
        method: "tools/call",
        params: ["name": "pearfy.populate.run"]
    )
    #expect((removedWriteTool["result"] as? [String: Any])?["isError"] as? Bool == true)

    let staticKnowledgeTool = try responseObject(
        from: handler,
        id: 5,
        method: "tools/call",
        params: ["name": "pearfy.modules.list"]
    )
    #expect((staticKnowledgeTool["result"] as? [String: Any])?["isError"] as? Bool == true)

    let resources = try #require((responseObject(from: handler, id: 8, method: "resources/list")["result"] as? [String: Any])?["resources"] as? [[String: Any]])
    #expect(resources.map { $0["uri"] as? String } == ["pearfy://populate/schema"])

    #expect(try manager.doctor(projectRoot: projectRoot) == ["http", "populate"])
    #expect(try Data(contentsOf: manifestURL).range(of: Data("PearfyPopulateCore".utf8)) != nil)
    #expect(try Data(contentsOf: lockURL).range(of: Data("populate".utf8)) != nil)

    #expect(handler.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
}

private func responseObject(
    from handler: PearfyMCPRequestHandler,
    id: Int,
    method: String,
    params: [String: Any]? = nil
) throws -> [String: Any] {
    var request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
    if let params { request["params"] = params }
    let line = try JSONSerialization.data(withJSONObject: request)
    let response = try #require(handler.handle(line: String(decoding: line, as: UTF8.self)))
    return try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
}

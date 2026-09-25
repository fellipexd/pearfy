import Foundation
@testable import PearfyCLIKit
import Testing

@Test func pearfyMCPNegotiatesListsReadOnlyToolsAndPlansModuleChanges() throws {
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
    #expect(Set(tools.compactMap { $0["name"] as? String }) == [
        "pearfy.project.inspect",
        "pearfy.modules.list",
        "pearfy.modules.inspect",
        "pearfy.modules.plan"
    ])

    let manifestURL = projectRoot.appendingPathComponent("Package.swift")
    let lockURL = projectRoot.appendingPathComponent(".pearfy/modules.json")
    let originalManifest = try Data(contentsOf: manifestURL)
    let originalLock = try Data(contentsOf: lockURL)
    let planResponse = try responseObject(
        from: handler,
        id: 3,
        method: "tools/call",
        params: [
            "name": "pearfy.modules.plan",
            "arguments": ["action": "add", "module": "postgres"]
        ]
    )
    let planContent = try #require((planResponse["result"] as? [String: Any])?["content"] as? [[String: Any]])
    let planText = try #require(planContent.first?["text"] as? String)
    let plan = try #require(try JSONSerialization.jsonObject(with: Data(planText.utf8)) as? [String: Any])
    #expect(plan["productsToAdd"] as? [String] == ["PearfyData", "PearfyPostgres", "PearfyTransactions"])
    #expect(plan["readOnly"] as? Bool == true)
    #expect(try Data(contentsOf: manifestURL) == originalManifest)
    #expect(try Data(contentsOf: lockURL) == originalLock)

    let resourceResponse = try responseObject(
        from: handler,
        id: 4,
        method: "resources/read",
        params: ["uri": "pearfy://modules/postgres"]
    )
    let resources = try #require((resourceResponse["result"] as? [String: Any])?["contents"] as? [[String: Any]])
    let resourceText = try #require(resources.first?["text"] as? String)
    let module = try #require(try JSONSerialization.jsonObject(with: Data(resourceText.utf8)) as? [String: Any])
    #expect(module["id"] as? String == "postgres")

    let invalidPlanResponse = try responseObject(
        from: handler,
        id: 5,
        method: "tools/call",
        params: [
            "name": "pearfy.modules.plan",
            "arguments": ["action": "overwrite", "module": "postgres"]
        ]
    )
    #expect((invalidPlanResponse["result"] as? [String: Any])?["isError"] as? Bool == true)
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

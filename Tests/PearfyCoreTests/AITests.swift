import Foundation
import PearfyAI
import PearfyCloud
import Testing

@Test func openAICompatibleClientDecodesResponsesAndUsesExplicitTransport() async throws {
    let body = Data(#"{"model":"test-model","choices":[{"message":{"content":"hello"}}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}"#.utf8)
    let transport = StubHTTPTransport(response: CloudHTTPResponse(statusCode: 200, headers: [:], body: body))
    let client = try OpenAICompatibleClient(baseURL: URL(string: "https://example.test/v1")!, apiKey: "test-key", transport: transport)
    let result = try await client.complete(
        model: "test-model",
        messages: [AIChatMessage(role: .user, content: "hello")],
        temperature: 0.2,
        maximumTokens: 32
    )

    #expect(result.content == "hello")
    #expect(result.model == "test-model")
    #expect(result.usage == AIUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5))
    let request = await transport.request
    #expect(request?.url?.absoluteString == "https://example.test/v1/chat/completions")
    #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
}

@Test func openAICompatibleClientRejectsInsecureRemoteEndpointsAndProviderErrors() async throws {
    var insecureEndpointRejected = false
    do {
        _ = try OpenAICompatibleClient(baseURL: URL(string: "http://example.test")!, apiKey: "key")
    } catch AIProviderError.invalidConfiguration {
        insecureEndpointRejected = true
    }
    #expect(insecureEndpointRejected)

    let transport = StubHTTPTransport(response: CloudHTTPResponse(statusCode: 401, headers: [:], body: Data("unauthorized".utf8)))
    let client = try OpenAICompatibleClient(baseURL: URL(string: "https://example.test")!, apiKey: "key", transport: transport)
    var statusRejected = false
    do {
        _ = try await client.complete(model: "model", messages: [AIChatMessage(role: .user, content: "hi")])
    } catch AIProviderError.httpStatus(let status, _) {
        statusRejected = status == 401
    }
    #expect(statusRejected)
}

private actor StubHTTPTransport: CloudHTTPTransport {
    let response: CloudHTTPResponse
    private(set) var request: URLRequest?

    init(response: CloudHTTPResponse) { self.response = response }

    func send(_ request: URLRequest) async throws -> CloudHTTPResponse {
        self.request = request
        return response
    }
}

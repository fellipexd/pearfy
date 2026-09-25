import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PearfyCloud

public enum AIMessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

public struct AIChatMessage: Codable, Sendable, Equatable {
    public let role: AIMessageRole
    public let content: String

    public init(role: AIMessageRole, content: String) {
        self.role = role
        self.content = content
    }
}

public struct AIUsage: Codable, Sendable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

public struct AIChatResponse: Sendable, Equatable {
    public let content: String
    public let model: String
    public let usage: AIUsage?

    public init(content: String, model: String, usage: AIUsage? = nil) {
        self.content = content
        self.model = model
        self.usage = usage
    }
}

public protocol AIProvider: Sendable {
    func complete(
        model: String,
        messages: [AIChatMessage],
        temperature: Double?,
        maximumTokens: Int?
    ) async throws -> AIChatResponse
}

public enum AIProviderError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidConfiguration(String)
    case invalidRequest(String)
    case httpStatus(Int, String)
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .invalidConfiguration(let message): "PEARFY_AI_001: \(message)"
        case .invalidRequest(let message): "PEARFY_AI_002: \(message)"
        case .httpStatus(let status, let message): "PEARFY_AI_003: provider returned HTTP \(status): \(message)"
        case .invalidResponse(let message): "PEARFY_AI_004: \(message)"
        }
    }
}

/// OpenAI-compatible chat-completions adapter. The endpoint and API key are
/// explicitly supplied so credentials never come from implicit global state.
public struct OpenAICompatibleClient: AIProvider {
    private struct RequestBody: Encodable {
        let model: String
        let messages: [AIChatMessage]
        let temperature: Double?
        let maximumTokens: Int?

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case maximumTokens = "max_tokens"
        }
    }

    private struct CompletionBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        struct Usage: Decodable {
            let promptTokens: Int
            let completionTokens: Int
            let totalTokens: Int
        }
        let model: String?
        let choices: [Choice]
        let usage: Usage?
    }

    private let endpoint: URL
    private let apiKey: String
    private let transport: any CloudHTTPTransport

    public init(
        baseURL: URL = URL(string: "https://api.openai.com")!,
        apiKey: String,
        transport: any CloudHTTPTransport = CloudHTTPClient()
    ) throws {
        guard let scheme = baseURL.scheme?.lowercased(),
              let host = baseURL.host?.lowercased(),
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
        else {
            throw AIProviderError.invalidConfiguration("base URL must use HTTPS (HTTP is allowed for localhost)")
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidConfiguration("API key must not be empty")
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var path = components?.path ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/v1") { path += "/v1" }
        components?.path = path + "/chat/completions"
        components?.query = nil
        components?.fragment = nil
        guard let endpoint = components?.url else {
            throw AIProviderError.invalidConfiguration("could not construct chat-completions endpoint")
        }
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.transport = transport
    }

    public func complete(
        model: String,
        messages: [AIChatMessage],
        temperature: Double? = nil,
        maximumTokens: Int? = nil
    ) async throws -> AIChatResponse {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !messages.isEmpty else {
            throw AIProviderError.invalidRequest("model and at least one message are required")
        }
        guard temperature.map({ (0...2).contains($0) }) ?? true else {
            throw AIProviderError.invalidRequest("temperature must be between 0 and 2")
        }
        guard maximumTokens.map({ $0 > 0 }) ?? true else {
            throw AIProviderError.invalidRequest("maximumTokens must be positive")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: model,
            messages: messages,
            temperature: temperature,
            maximumTokens: maximumTokens
        ))

        let response = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            let body = String(decoding: response.body.prefix(1_000), as: UTF8.self)
            throw AIProviderError.httpStatus(response.statusCode, body)
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let body = try decoder.decode(CompletionBody.self, from: response.body)
            guard let choice = body.choices.first else {
                throw AIProviderError.invalidResponse("provider returned no completion choices")
            }
            let usage = body.usage.map {
                AIUsage(promptTokens: $0.promptTokens, completionTokens: $0.completionTokens, totalTokens: $0.totalTokens)
            }
            return AIChatResponse(content: choice.message.content, model: body.model ?? model, usage: usage)
        } catch let error as AIProviderError {
            throw error
        } catch {
            throw AIProviderError.invalidResponse(String(describing: error))
        }
    }
}

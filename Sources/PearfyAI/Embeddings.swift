import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PearfyCloud

public struct AIEmbedding: Sendable, Equatable {
    public let values: [Double]
    public let model: String

    public init(values: [Double], model: String) throws {
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite }) else {
            throw AIProviderError.invalidResponse("embedding must contain finite values")
        }
        self.values = values
        self.model = model
    }
}

public protocol EmbeddingProvider: Sendable {
    func embed(_ input: String, model: String) async throws -> AIEmbedding
}

/// OpenAI-compatible embeddings adapter, including local endpoints.
public struct OpenAICompatibleEmbeddingClient: EmbeddingProvider, Sendable {
    private struct RequestBody: Encodable {
        let input: String
        let model: String
    }

    private struct ResponseBody: Decodable {
        struct Item: Decodable {
            let embedding: [Double]
            let index: Int
        }
        let data: [Item]
        let model: String?
    }

    private let endpoint: URL
    private let apiKey: String
    private let transport: any CloudHTTPTransport

    public init(
        baseURL: URL,
        apiKey: String,
        transport: any CloudHTTPTransport = CloudHTTPClient()
    ) throws {
        guard let scheme = baseURL.scheme?.lowercased(),
              let host = baseURL.host?.lowercased(),
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw AIProviderError.invalidConfiguration("base URL must use HTTPS (HTTP is allowed for localhost)")
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidConfiguration("API key must not be empty")
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var path = components?.path ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/v1") { path += "/v1" }
        components?.path = path + "/embeddings"
        components?.query = nil
        components?.fragment = nil
        guard let endpoint = components?.url else {
            throw AIProviderError.invalidConfiguration("could not construct embeddings endpoint")
        }
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.transport = transport
    }

    public func embed(_ input: String, model: String) async throws -> AIEmbedding {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidRequest("input and model are required")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(input: input, model: model))
        let response = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            throw AIProviderError.httpStatus(response.statusCode, "embeddings provider request failed")
        }
        do {
            let decoded = try JSONDecoder().decode(ResponseBody.self, from: response.body)
            guard let item = decoded.data.first else {
                throw AIProviderError.invalidResponse("provider returned no embedding")
            }
            return try AIEmbedding(values: item.embedding, model: decoded.model ?? model)
        } catch let error as AIProviderError {
            throw error
        } catch {
            throw AIProviderError.invalidResponse("provider returned an invalid embedding response")
        }
    }
}

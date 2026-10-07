import Foundation
import PearfyCloud
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct JevChoiceOption: Sendable, Equatable, Identifiable {
    public let id: String
    public let description: String

    public init(id: String, description: String) {
        self.id = id
        self.description = description
    }
}

public struct JevChoiceDecision: Sendable, Equatable {
    public let choice: String
    public let confidence: Double
    public let probabilities: [String: Double]
    public let model: String

    public init(choice: String, confidence: Double, probabilities: [String: Double], model: String) {
        self.choice = choice
        self.confidence = confidence
        self.probabilities = probabilities
        self.model = model
    }
}

public protocol JevDecisionProvider: Sendable {
    func choose(
        state: String,
        question: String,
        options: [JevChoiceOption]
    ) async throws -> JevChoiceDecision
}

/// TypeSafe Jev's typed choice primitive. Credentials are supplied explicitly
/// and must remain in server-side configuration.
public struct JevDecisionClient: JevDecisionProvider, Sendable {
    private struct ChoiceQuestion: Encodable {
        let type = "choice"
        let instructions: String
        let criteria: [String: String]
    }
    private struct RequestBody: Encodable {
        let model: String
        let state: String
        let questions: [String: ChoiceQuestion]
    }
    private struct ResponseBody: Decodable {
        struct Answer: Decodable {
            let type: String
            let choice: String
            let confidence: Double
            let probabilities: [String: Double]
        }
        let model: String
        let answers: [String: Answer]
    }

    private let endpoint: URL
    private let apiKey: String
    private let model: String
    private let transport: any CloudHTTPTransport
    private let maximumStateBytes: Int
    private let maximumOptions: Int

    public init(
        apiKey: String,
        model: String = "jev-latest",
        endpoint: URL = URL(string: "https://api.typesafe.ai/v1/systemone")!,
        transport: any CloudHTTPTransport = CloudHTTPClient(),
        maximumStateBytes: Int = 16_384,
        maximumOptions: Int = 32
    ) throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
            throw AIProviderError.invalidConfiguration("Jev endpoint must use HTTPS")
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              maximumStateBytes > 0, (2...255).contains(maximumOptions) else {
            throw AIProviderError.invalidConfiguration("invalid Jev client configuration")
        }
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
        self.maximumStateBytes = maximumStateBytes
        self.maximumOptions = maximumOptions
    }

    public func choose(state: String, question: String, options: [JevChoiceOption]) async throws -> JevChoiceDecision {
        let stateData = Data(state.utf8)
        guard !state.isEmpty, stateData.count <= maximumStateBytes,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.utf8.count <= 1_024,
              options.count >= 2, options.count <= maximumOptions,
              Set(options.map(\.id)).count == options.count,
              options.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 && !$0.description.isEmpty && $0.description.utf8.count <= 512 }) else {
            throw AIProviderError.invalidRequest("invalid or over-capacity Jev decision input")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: model,
            state: state,
            questions: ["npc_action": ChoiceQuestion(
                instructions: question,
                criteria: Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0.description) })
            )]
        ))
        let response = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            throw AIProviderError.httpStatus(response.statusCode, "Jev decision request failed")
        }
        guard response.body.count <= 65_536 else {
            throw AIProviderError.invalidResponse("Jev response exceeded the configured size limit")
        }
        do {
            let body = try JSONDecoder().decode(ResponseBody.self, from: response.body)
            guard let answer = body.answers["npc_action"], answer.type == "choice",
                  options.contains(where: { $0.id == answer.choice }),
                  answer.confidence.isFinite, (0...1).contains(answer.confidence),
                  answer.probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw AIProviderError.invalidResponse("Jev returned an invalid typed choice")
            }
            return JevChoiceDecision(choice: answer.choice, confidence: answer.confidence,
                                     probabilities: answer.probabilities, model: body.model)
        } catch let error as AIProviderError { throw error }
        catch { throw AIProviderError.invalidResponse("Jev response could not be decoded") }
    }
}

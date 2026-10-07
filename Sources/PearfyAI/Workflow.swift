import Foundation

public protocol AIWorkflow: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable
    func run(_ input: Input) async throws -> Output
}

public protocol StructuredAIOutput: Decodable, Sendable {}

public struct RAGFilter: Sendable, Equatable {
    public let type: String
    public let category: String?
    public let language: String
    public let communityID: UUID?
    public let gameID: UUID?
    public let activeOnly: Bool

    public init(
        type: String,
        category: String? = nil,
        language: String,
        communityID: UUID? = nil,
        gameID: UUID? = nil,
        activeOnly: Bool = true
    ) {
        self.type = type
        self.category = category
        self.language = language
        self.communityID = communityID
        self.gameID = gameID
        self.activeOnly = activeOnly
    }
}

public struct RAGChunk: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let documentID: UUID
    public let content: String
    public let metadata: [String: String]
    public let version: Int
    public let similarity: Double
    public let rerankScore: Double

    public init(
        id: UUID,
        documentID: UUID,
        content: String,
        metadata: [String: String],
        version: Int,
        similarity: Double,
        rerankScore: Double
    ) {
        self.id = id
        self.documentID = documentID
        self.content = content
        self.metadata = metadata
        self.version = version
        self.similarity = similarity
        self.rerankScore = rerankScore
    }
}

public protocol RAGRetriever: Sendable {
    func retrieve(query: String, filter: RAGFilter, limit: Int) async throws -> [RAGChunk]
}

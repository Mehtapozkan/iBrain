import Foundation
import NaturalLanguage

/// Vectors may be compared only within exactly one space. Apple does not
/// expose its asset checksum; environment includes the OS build. No vectors
/// in this prototype are persisted or transferred between devices.
public struct TextVectorSpace: Codable, Hashable, Sendable {
    public let provider: String
    public let revision: String
    public let language: String
    public let dimension: Int
    public let environment: String
    public init(provider: String, revision: String, language: String, dimension: Int, environment: String) {
        self.provider = provider; self.revision = revision; self.language = language
        self.dimension = dimension; self.environment = environment
    }
    var isValid: Bool {
        !provider.isEmpty && !revision.isEmpty && !language.isEmpty && !environment.isEmpty && (1...4096).contains(dimension)
    }
}
public protocol TextEncoder: Sendable {
    var space: TextVectorSpace { get }
    func encode(_ text: String) async throws -> [Double]
}
public enum SourceSearchError: Error, Equatable, Sendable {
    case encoderUnavailable, invalidVector, changedVectorSpace, invalidQuery, invalidLimit, invalidResult, inputTooLong
}

/// Explicitly English, pinned revision; no requestAssets, download, external
/// service, retry or fallback. Availability is specific to the running device.
public actor AppleSentenceEncoder: TextEncoder {
    public nonisolated let space: TextVectorSpace
    private let embedding: NLEmbedding
    public init(revision: Int = 1) throws {
        guard revision > 0, let model = NLEmbedding.sentenceEmbedding(for: .english, revision: revision),
              model.revision == revision, model.language == .english else { throw SourceSearchError.encoderUnavailable }
        embedding = model
        space = TextVectorSpace(provider: "apple.naturallanguage.sentence", revision: String(model.revision), language: "en",
                                dimension: model.dimension, environment: ProcessInfo.processInfo.operatingSystemVersionString)
    }
    public func encode(_ text: String) throws -> [Double] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SourceSearchError.invalidVector }
        guard text.utf8.count <= 16_384 else { throw SourceSearchError.inputTooLong }
        guard let vector = embedding.vector(for: text) else { throw SourceSearchError.invalidVector }
        return vector
    }
}

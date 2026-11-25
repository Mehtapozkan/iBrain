import Foundation
import CryptoKit
import IBrain

public enum SourceSearchStrategy: String, Codable, Sendable { case lexical, semantic, hybrid }
public struct SourceCandidate: Codable, Equatable, Sendable {
    public let source: SourceReference
    /// Ranking score, never a probability or factual confidence.
    public let score: Double
}
public struct SourceSearchDiagnostics: Sendable {
    public let sourceCount: Int
    public let newSourceVectors: Int
    public let reusedSourceVectors: Int
}
/// Provisional originals, including empty sets. Recheck with `admit` at the
/// owning publication boundary. No inferred domain records are returned.
public struct PreparedSourceCandidates: Sendable {
    public let requestID: UUID
    public let query: String
    public let strategy: SourceSearchStrategy
    public let matches: [SourceCandidate]
    public let vectorSpace: TextVectorSpace?
    public let diagnostics: SourceSearchDiagnostics
    fileprivate let owner: UUID
    fileprivate let permit: SnapshotPermit
}

/// Experimental explicit candidate API. It is not wired into recognized
/// appointment routes. Process-local vectors and BM25 inputs are rebuildable.
public actor SourceCandidateSearch {
    private let store: MemoryStore
    private let encoder: (any TextEncoder)?
    private let identity = UUID()
    private struct Entry {
        let source: SourceReference
        let text: String
        let digest: String
        var space: TextVectorSpace?
        var vector: [Double]?
    }
    private var cache: [String: Entry] = [:]
    public init(store: MemoryStore, encoder: (any TextEncoder)? = nil) { self.store = store; self.encoder = encoder }

    public func prepare(query: String, strategy: SourceSearchStrategy, limit: Int = 5,
                        requestID: UUID, permit: SnapshotPermit) async throws -> PreparedSourceCandidates {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SourceSearchError.invalidQuery }
        guard query.utf8.count <= 16_384 else { throw SourceSearchError.inputTooLong }
        guard (1...1000).contains(limit) else { throw SourceSearchError.invalidLimit }
        let snapshot = try await store.sourceSearchSnapshot(permit: permit)
        let usesVectors = strategy != .lexical
        let space = usesVectors ? encoder?.space : nil
        if usesVectors && (encoder == nil || space?.isValid != true) { throw SourceSearchError.encoderUnavailable }
        var next: [String: Entry] = [:]
        for source in snapshot.sources {
            let text = source.observations.filter { $0.kind == .text }.map(\.value).joined(separator: "\n")
            guard !text.isEmpty else { continue }
            let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            let old = cache[source.reference.id]
            next[source.reference.id] = old?.source == source.reference && old?.digest == digest ? old :
                Entry(source: source.reference, text: text, digest: digest)
        }
        // Prune removed or changed inputs even if a later encoder fails. The
        // host invokes prepare after invalidation; no secure-erasure claim.
        cache = cache.filter { id, old in next[id]?.source == old.source && next[id]?.digest == old.digest }
        var newVectors = 0, reusedVectors = 0
        if usesVectors {
            for id in next.keys.sorted() {
                if next[id]!.space == space, next[id]!.vector != nil { reusedVectors += 1; continue }
                let vector = try await encoder!.encode(next[id]!.text)
                try await store.validate(snapshot.permit)
                guard encoder!.space == space else { throw SourceSearchError.changedVectorSpace }
                next[id]!.vector = try SourceRanking.normalized(vector, space: space!)
                next[id]!.space = space; newVectors += 1
            }
        }
        let documents = next.map { SourceRanking.Document(id: $0.key, text: $0.value.text) }.sorted { $0.id < $1.id }
        let lexical = strategy == .semantic ? [] : SourceRanking.lexical(documents, query: query)
        var semantic: [SourceRanking.Rank] = []
        if usesVectors {
            let vector = try await encoder!.encode(query)
            guard encoder!.space == space else { throw SourceSearchError.changedVectorSpace }
            semantic = SourceRanking.semantic(next.mapValues { $0.vector! }, query: try SourceRanking.normalized(vector, space: space!))
        }
        let ranks: [SourceRanking.Rank]
        switch strategy { case .lexical: ranks = lexical; case .semantic: ranks = semantic; case .hybrid: ranks = SourceRanking.hybrid(lexical, semantic) }
        try await store.validate(snapshot.permit)
        if usesVectors && encoder!.space != space { throw SourceSearchError.changedVectorSpace }
        cache = next
        return PreparedSourceCandidates(requestID: requestID, query: query, strategy: strategy,
            matches: ranks.prefix(limit).map { SourceCandidate(source: next[$0.id]!.source, score: $0.score) }, vectorSpace: space,
            diagnostics: SourceSearchDiagnostics(sourceCount: next.count, newSourceVectors: newVectors, reusedSourceVectors: reusedVectors),
            owner: identity, permit: snapshot.permit)
    }

    /// Recheck immediately before publication. The host still serializes its
    /// own source-authority updates with display/publication as for answers.
    @discardableResult
    public func admit(_ result: PreparedSourceCandidates, activeRequestID: UUID) async throws -> PreparedSourceCandidates {
        guard result.owner == identity else { throw SourceSearchError.invalidResult }
        guard result.requestID == activeRequestID else { throw MemoryError.staleResult }
        if let space = result.vectorSpace, encoder?.space != space { throw SourceSearchError.changedVectorSpace }
        do { try await store.validate(result.permit) } catch { throw MemoryError.staleResult }
        if let space = result.vectorSpace, encoder?.space != space { throw SourceSearchError.changedVectorSpace }
        return result
    }
}

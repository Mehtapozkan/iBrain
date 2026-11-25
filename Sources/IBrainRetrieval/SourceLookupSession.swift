import Foundation
import IBrain
import IBrainSemantics

public enum SourceLookupStage: String, Sendable { case noCandidates, inspected }

/// Original-image lookup only. Keep the opaque prepared value through final
/// admission; neither an empty rank nor an inspected no-match is global absence.
public struct PreparedSourceLookup: Sendable {
    public let requestID: UUID
    public var query: String { ranking.query }
    public var candidates: [SourceCandidate] { ranking.matches }
    public var diagnostics: SourceSearchDiagnostics { ranking.diagnostics }
    public var relevance: SourceRelevanceResult? { proposal?.result }
    public var semanticTaskID: String? { proposal?.taskID }
    public var stage: SourceLookupStage { proposal == nil ? .noCandidates : .inspected }
    public var canAssertPersonalCalendarIsEmpty: Bool { false }
    fileprivate let owner: UUID
    fileprivate let ranking: PreparedSourceCandidates
    fileprivate let proposal: BoundSourceRelevanceProposal?
}

/// Explicit opt-in ranking → bounded relevance composition. No appointment
/// routing, domain admission, effect, provider fallback or vector persistence.
public actor SourceLookupSession {
    private let identity = UUID()
    private let store: MemoryStore
    private let search: SourceCandidateSearch
    private let filter: BoundedSourceRelevanceFilter
    private let beforeRelevanceForTesting: (@Sendable () async throws -> Void)?

    public init(store: MemoryStore, encoder: (any TextEncoder)? = nil, provider: any DecisionProvider) {
        self.store = store; self.search = SourceCandidateSearch(store:store,encoder:encoder)
        self.filter = BoundedSourceRelevanceFilter(provider:provider); self.beforeRelevanceForTesting = nil
    }
    // Deterministic authority-change barrier for the cross-stage grant test.
    // It is not a production callback or public provider extension.
    init(store: MemoryStore, encoder: (any TextEncoder)?, provider: any DecisionProvider,
         beforeRelevanceForTesting: @escaping @Sendable () async throws -> Void) {
        self.store = store; self.search = SourceCandidateSearch(store:store,encoder:encoder)
        self.filter = BoundedSourceRelevanceFilter(provider:provider); self.beforeRelevanceForTesting = beforeRelevanceForTesting
    }

    public func prepare(query: String, requestID: UUID, strategy: SourceSearchStrategy = .hybrid,
                        candidateLimit: Int = 5) async throws -> PreparedSourceLookup {
        guard (1...12).contains(candidateLimit) else { throw SourceSearchError.invalidLimit }
        let originalPermit = try await store.permit()
        let ranking = try await search.prepare(query:query,strategy:strategy,limit:candidateLimit,requestID:requestID,permit:originalPermit)
        try await search.admit(ranking,activeRequestID:requestID)
        guard !ranking.matches.isEmpty else {
            return PreparedSourceLookup(requestID:requestID,owner:identity,ranking:ranking,proposal:nil)
        }
        let snapshot = try await store.sourceSearchSnapshot(permit:originalPermit)
        let available = Dictionary(uniqueKeysWithValues:snapshot.sources.map { ($0.reference.id,$0) })
        let selected = try ranking.matches.map { candidate -> SourceSnapshot in
            guard let source = available[candidate.source.id], source.reference == candidate.source else { throw MemoryError.staleResult }
            return source
        }
        if let barrier = beforeRelevanceForTesting { try await barrier() }
        let taskID = "lookup-"+requestID.uuidString.lowercased()
        let request = SourceRelevanceRequest(taskID:taskID,query:query,sources:selected)
        let proposal = try await SemanticSession.sourceRelevance(request,filter:filter,store:store)
        // The relevance session can capture a newer grant in a gap between
        // stages. Its validity alone cannot make an old ranking current.
        try await search.admit(ranking,activeRequestID:requestID)
        _ = try await SemanticSession.admitSourceRelevance(proposal,activeTaskID:taskID,store:store)
        return PreparedSourceLookup(requestID:requestID,owner:identity,ranking:ranking,proposal:proposal)
    }

    @discardableResult
    public func admit(_ prepared: PreparedSourceLookup, activeRequestID: UUID) async throws -> PreparedSourceLookup {
        guard prepared.owner == identity else { throw SourceSearchError.invalidResult }
        guard prepared.requestID == activeRequestID else { throw MemoryError.staleResult }
        try await search.admit(prepared.ranking,activeRequestID:activeRequestID)
        if let proposal = prepared.proposal {
            _ = try await SemanticSession.admitSourceRelevance(proposal,activeTaskID:"lookup-"+activeRequestID.uuidString.lowercased(),store:store)
        }
        return prepared
    }
}

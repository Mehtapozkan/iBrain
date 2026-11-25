import Foundation
import IBrain
import IBrainSemantics

public struct AppointmentRetrievalCoverage:Sendable {
    public let accessibleSources:Int
    public let sourcesWithSearchableText:Int
    public let inspectedSources:Int
    public let admittedRecords:Int
    public let candidateRecords:Int
    public var entireAdmittedInventory:Bool {false}
    public var canAssertGlobalAbsence:Bool {false}
}
public enum AppointmentRetrievalStage:String,Sendable {case noRankedCandidates,noRelevantCandidates,sourcePreparationRequired,candidatesReady}
/// Keep this opaque preparation until publication. Source relevance nominates
/// candidates, never manufactures records or proves all question conditions.
public struct PreparedAppointmentRetrieval:Sendable {
    public let requestID:UUID
    public let query:String
    public let recordIDs:Set<String>
    public let coverage:AppointmentRetrievalCoverage
    public let relevantSources:[RelevantSource]
    public let unresolvedSources:[UnresolvedSourceRelevance]
    public let sourcesWithoutRecords:Set<SourceReference>
    public var stage:AppointmentRetrievalStage {
        if lookup.candidates.isEmpty{return .noRankedCandidates}
        if relevantSources.isEmpty && unresolvedSources.isEmpty{return .noRelevantCandidates}
        return recordIDs.isEmpty ? .sourcePreparationRequired:.candidatesReady
    }
    public var needsSourcePreparation:Bool {!sourcesWithoutRecords.isEmpty}
    public var recordScope:EvidenceRecordScope {.retrievedCandidates(recordIDs)}
    fileprivate let owner:UUID
    fileprivate let permit:SnapshotPermit
    fileprivate let lookup:PreparedSourceLookup
}
public struct PreparedRetrievedAppointmentAnswer:Sendable {
    public let retrieval:PreparedAppointmentRetrieval
    /// Nil means no existing canonical candidate was available, NOT no match
    /// in the library. Consult coverage and source-preparation gaps.
    public let answer:EvidenceQuestionAnswer?
    fileprivate let owner:UUID
    fileprivate var selectedContext:EvidenceQuestionContext? = nil
    public var context:EvidenceQuestionContext? {selectedContext ?? answer?.context}
}

/// Experimental opt-in bridge from photo candidates to existing appointment
/// records. Source/record linkage is native; answer semantics are still needed.
/// This never routes recognized appointment questions to a lexical final answer.
public actor AppointmentRetrievalSession {
    private let identity=UUID()
    private let store:MemoryStore
    private let lookup:SourceLookupSession
    public init(store:MemoryStore,encoder:(any TextEncoder)?=nil,relevanceProvider:any DecisionProvider) {
        self.store=store;lookup=SourceLookupSession(store:store,encoder:encoder,provider:relevanceProvider)
    }
    public func prepare(query:String,requestID:UUID,strategy:SourceSearchStrategy = .hybrid,candidateLimit:Int=12)async throws->PreparedAppointmentRetrieval {
        let permit=try await store.permit()
        let sources=try await store.sourceSearchSnapshot(permit:permit)
        let result=try await lookup.prepare(query:query,requestID:requestID,strategy:strategy,candidateLimit:candidateLimit)
        try await store.validate(permit)
        _ = try await lookup.admit(result,activeRequestID:requestID)
        let relevant=result.relevance?.matches ?? [],unresolved=result.relevance?.unresolved ?? []
        // Unclear sources are included for further inspection, not discarded.
        let refs=Set(relevant.map(\.source)+unresolved.map(\.source))
        let selection=try await store.recordsSupportedBy(refs,permit:permit)
        try await store.validate(permit)
        return PreparedAppointmentRetrieval(requestID:requestID,query:query,recordIDs:selection.recordIDs,
            coverage:AppointmentRetrievalCoverage(accessibleSources:sources.sources.count,sourcesWithSearchableText:result.diagnostics.sourceCount,inspectedSources:result.relevance?.inspectedSources.count ?? 0,admittedRecords:selection.admittedRecordCount,candidateRecords:selection.recordIDs.count),
            relevantSources:relevant,unresolvedSources:unresolved,sourcesWithoutRecords:selection.unlinkedSources,owner:identity,permit:permit,lookup:result)
    }
    public func answer(_ prepared:PreparedAppointmentRetrieval,activeRequestID:UUID,taskID:String,now:Date,calendar:Calendar,provider:any DecisionProvider,inferredDatePolicy:InferredDatePolicy = .explicitOnly)async throws->PreparedRetrievedAppointmentAnswer {
        try await validate(prepared,activeRequestID:activeRequestID)
        guard !prepared.recordIDs.isEmpty else{return PreparedRetrievedAppointmentAnswer(retrieval:prepared,answer:nil,owner:identity)}
        let input=EvidenceQuestionInput(taskID:taskID,question:prepared.query,now:now,calendar:calendar,policy:.completeV9,inferredDatePolicy:inferredDatePolicy,temporalScopePolicy:.inventoryVsEventTimeV1,recordScope:prepared.recordScope)
        let answer=try await EvidenceQuestionSession.answer(input,provider:provider,store:store)
        try await validate(prepared,activeRequestID:activeRequestID)
        return PreparedRetrievedAppointmentAnswer(retrieval:prepared,answer:answer,owner:identity)
    }
    /// Follow-ups use the actual admitted answer context and the same declared
    /// candidate scope. A broader new search requires a new prepare operation.
    public func followup(_ previous:PreparedRetrievedAppointmentAnswer,activeRequestID:UUID,taskID:String,question:String,now:Date,calendar:Calendar,provider:any DecisionProvider,inferredDatePolicy:InferredDatePolicy = .explicitOnly)async throws->PreparedRetrievedAppointmentAnswer {
        _ = try await admit(previous,activeRequestID:activeRequestID)
        guard let context=previous.context else{throw MemoryError.invalidContext}
        let input=EvidenceQuestionInput(taskID:taskID,question:question,now:now,calendar:calendar,previous:context,activeContextID:context.answerID,policy:.completeV9,inferredDatePolicy:inferredDatePolicy,temporalScopePolicy:.inventoryVsEventTimeV1,recordScope:previous.retrieval.recordScope)
        let answer=try await EvidenceQuestionSession.answer(input,provider:provider,store:store)
        try await validate(previous.retrieval,activeRequestID:activeRequestID)
        return PreparedRetrievedAppointmentAnswer(retrieval:previous.retrieval,answer:answer,owner:identity)
    }
    /// A native original inspection selects only an actually displayed item.
    /// The result remains bound to the same answer, source permit and scope.
    public func selecting(recordID:String,in previous:PreparedRetrievedAppointmentAnswer,activeRequestID:UUID)async throws->PreparedRetrievedAppointmentAnswer {
        _ = try await admit(previous,activeRequestID:activeRequestID)
        guard let context=previous.context else{throw MemoryError.invalidContext}
        let selected=try await EvidenceQuestionSelection.selecting(recordID:recordID,in:context,activeAnswerID:context.answerID,store:store)
        try await validate(previous.retrieval,activeRequestID:activeRequestID)
        var result=previous;result.selectedContext=selected;return result
    }
    @discardableResult public func admit(_ result:PreparedRetrievedAppointmentAnswer,activeRequestID:UUID)async throws->PreparedRetrievedAppointmentAnswer {
        guard result.owner==identity else{throw SourceSearchError.invalidResult}
        try await validate(result.retrieval,activeRequestID:activeRequestID)
        return result
    }
    private func validate(_ prepared:PreparedAppointmentRetrieval,activeRequestID:UUID)async throws {
        guard prepared.owner==identity else{throw SourceSearchError.invalidResult}
        guard prepared.requestID==activeRequestID else{throw MemoryError.staleResult}
        do{try await store.validate(prepared.permit)}catch{throw MemoryError.staleResult}
        _ = try await lookup.admit(prepared.lookup,activeRequestID:activeRequestID)
    }
}

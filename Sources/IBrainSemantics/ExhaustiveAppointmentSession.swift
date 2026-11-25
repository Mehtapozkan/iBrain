import Foundation
import IBrain

public enum MissingEvidenceReason:String,Codable,Sendable {case requestedDetail,queryCondition,sourceReading,sourcePreparation,statusEvidence}
public struct MissingEvidenceTarget:Sendable {
    public let source:SourceReference
    public let recordIDs:Set<String>
    public let fields:Set<RequestedAppointmentDetail>
    public let reasons:Set<MissingEvidenceReason>
}
public struct ExhaustiveAppointmentCoverage:Sendable {
    public let totalRecords:Int
    public let inspectedRecords:Int
    public let unknownMembershipRecords:Int
    public let unprojectedRecords:Int
    public let unlinkedSources:Int
    public let sourcesWithReadingGaps:Int
    public let pendingSourcePreparations:Int
    public var entireAdmittedInventory:Bool {inspectedRecords==totalRecords}
    public var membershipComplete:Bool {entireAdmittedInventory && unknownMembershipRecords==0}
    public var preparedSourceCoverageComplete:Bool {membershipComplete && unprojectedRecords==0 && unlinkedSources==0 && sourcesWithReadingGaps==0 && pendingSourcePreparations==0}
    public var personalCalendarComplete:Bool {false}
}
/// Validated question meaning for ONE active user request. This carries no
/// records, source grants or answer authority; evidence must be scanned anew.
/// No public initializer or Codable restoration can manufacture this token.
public struct ExhaustiveQuestionInterpretation:Sendable {
    fileprivate let requestID:UUID
    fileprivate let input:EvidenceQuestionInput
    fileprivate let plan:ExhaustiveAppointmentPlan
}
public struct ExhaustiveAppointmentAnswer:Sendable {
    public let interpretation:ExhaustiveQuestionInterpretation
    public let requestID:UUID
    public let plan:ExhaustiveAppointmentPlan
    /// Every certain member, including those with missing requested details.
    public let matches:[StoredMemory]
    public let uncertain:[StoredMemory]
    public let unresolvedDetails:[String:Set<RequestedAppointmentDetail>]
    public let rereadTargets:[MissingEvidenceTarget]
    public let coverage:ExhaustiveAppointmentCoverage
    /// Counts canonical admitted records, never number of photos/ticket stubs.
    public var admittedCountLowerBound:Int {plan.resultUnit == nil ? matches.count:0}
    public var admittedCountUpperBound:Int {plan.resultUnit == nil ? matches.count+uncertain.count+coverage.totalRecords-coverage.inspectedRecords:coverage.totalRecords}
    public var exactAdmittedCount:Int? {plan.resultUnit == nil && coverage.membershipComplete ? matches.count:nil}
    /// Nil until every admitted member is decided and all matching instants are
    /// supported; ties are retained. Photo/source gaps still qualify this value.
    public let extremeRecords:[StoredMemory]?
    public var requestedAnswerComplete:Bool {plan.resultUnit == nil && plan.requestedSourceEvidence.isEmpty && plan.operation != .sourceEvidence && coverage.preparedSourceCoverageComplete && unresolvedDetails.isEmpty && ((plan.operation != .earliest && plan.operation != .latest) || extremeRecords != nil)}
    public var canAssertNoMatchInAdmittedRecords:Bool {plan.resultUnit == nil && coverage.membershipComplete && matches.isEmpty}
    /// A readable source plus one linked record is NOT proof that all events
    /// on that photo were extracted. V1 has no source-extraction certificate.
    public var canAssertNoMatchInPreparedSources:Bool {false}
    fileprivate let owner:UUID
    fileprivate let generation:Int
}

/// Process-local progressive scan. No model inference occurs inside page work.
/// Resume by calling advance again; never re-interpret a question per page.
/// All results, including empty results, require admit before publication.
public actor ExhaustiveAppointmentSession {
    private let store:MemoryStore
    private let identity=UUID()
    private var inventory:RecordInventory?
    private var plan:ExhaustiveAppointmentPlan?
    private var interpretation:ExhaustiveQuestionInterpretation?
    private var requestID:UUID?
    private var offset=0
    private var generation=0
    private var busy=false
    private var started=false
    private var displayedUnitContextID:UUID?
    private var installedDisplayedUnitIDs=Set<UUID>()
    private var matched:[StoredMemory]=[],uncertain:[StoredMemory]=[]
    private var details:[String:Set<RequestedAppointmentDetail>]=[:]
    private var targets:[SourceReference:MissingEvidenceTarget]=[:]
    public init(store:MemoryStore){self.store=store}

    /// Composed read/continuation adapters must use this same native authority,
    /// not another store that happens to contain equal projection bytes.
    public func validateMemoryStore(_ candidate:MemoryStore)throws {
        guard store === candidate else{throw MemoryError.invalidContext}
    }

    public func prepare(_ input:EvidenceQuestionInput,requestID:UUID,provider:any DecisionProvider,planningPolicy:ExhaustivePlanningPolicy = .inventoryV1)async throws->ExhaustiveAppointmentAnswer {
        guard !busy,!started else{throw SemanticError.existingAttempt}
        busy=true;started=true;defer{busy=false}
        let permit=try await store.permit(),inventory=try await store.recordInventory(permit:permit)
        let task=try ExhaustiveAppointmentPlanner.task(input,policy:planningPolicy)
        try Task.checkCancellation()
        let receipt=try await provider.decide(task)
        try Task.checkCancellation();try await store.validate(permit)
        let plan=try ExhaustiveAppointmentPlanner.compile(receipt,input:input,policy:planningPolicy)
        self.interpretation=ExhaustiveQuestionInterpretation(requestID:requestID,input:input,plan:plan)
        return try install(inventory:inventory,plan:plan,requestID:requestID)
    }

    /// Consume a typed branch of one original product decision. No synthetic
    /// provider receipt, second model call or changed request digest is used.
    public func prepare(_ input:EvidenceQuestionInput,requestID:UUID,productDecision:CompiledProductQuestion,planningPolicy:ExhaustivePlanningPolicy = .inventoryV1)async throws->ExhaustiveAppointmentAnswer {
        guard !busy,!started else{throw SemanticError.existingAttempt}
        busy=true;started=true;defer{busy=false}
        try await productDecision.validateCurrentAuthority(in:store)
        let permit=try await store.permit(),inventory=try await store.recordInventory(permit:permit)
        let plan=try ExhaustiveAppointmentPlanner.compile(productDecision,input:input,policy:planningPolicy)
        try Task.checkCancellation();try await store.validate(permit)
        try await productDecision.validateCurrentAuthority(in:store)
        self.interpretation=ExhaustiveQuestionInterpretation(requestID:requestID,input:input,plan:plan)
        return try install(inventory:inventory,plan:plan,requestID:requestID)
    }

    /// Compact interpretation preserves its actual tagged receipt and all
    /// native authority/admission checks; no legacy receipt is synthesized.
    public func prepare(_ input:EvidenceQuestionInput,requestID:UUID,compactDecision:CompiledCompactProductQuestion,planningPolicy:ExhaustivePlanningPolicy = .resultUnitsV4)async throws->ExhaustiveAppointmentAnswer {
        guard !busy,!started else{throw SemanticError.existingAttempt}
        busy=true;started=true;defer{busy=false}
        try await compactDecision.validateCurrentAuthority(in:store)
        let permit=try await store.permit(),inventory=try await store.recordInventory(permit:permit)
        let plan=try ExhaustiveAppointmentPlanner.compile(compactDecision:compactDecision,input:input,policy:planningPolicy)
        try Task.checkCancellation();try await store.validate(permit)
        try await compactDecision.validateCurrentAuthority(in:store)
        self.interpretation=ExhaustiveQuestionInterpretation(requestID:requestID,input:input,plan:plan)
        return try install(inventory:inventory,plan:plan,requestID:requestID)
    }

    /// Re-evaluate changed evidence under the same captured user meaning. The
    /// host keeps the submission clock/calendar and request identity fixed.
    /// No provider is called, no old answer/support is reused, and normal fresh
    /// inventory permits and final admission still apply.
    public func prepare(_ input:EvidenceQuestionInput,requestID:UUID,interpretation:ExhaustiveQuestionInterpretation)async throws->ExhaustiveAppointmentAnswer {
        guard !busy,!started else{throw SemanticError.existingAttempt}
        busy=true;started=true;defer{busy=false}
        let original=interpretation.input
        guard requestID==interpretation.requestID,input.taskID==original.taskID,input.question==original.question,
              input.now==original.now,input.calendar==original.calendar,
              input.inferredDatePolicy==original.inferredDatePolicy,input.policy==original.policy,
              input.temporalScopePolicy==original.temporalScopePolicy,input.recordScope==original.recordScope,
              input.clarificationPolicy==original.clarificationPolicy,
              input.activeContextID==original.activeContextID else{throw MemoryError.invalidContext}
        // Revalidate exact question/task bytes and compile the SAME receipt;
        // changed wording, task identity or unsupported prior context rejects.
        let plan:ExhaustiveAppointmentPlan
        if let compact=interpretation.plan.compactProductDecision {
            plan=try ExhaustiveAppointmentPlanner.compile(compactDecision:compact,input:input,policy:interpretation.plan.planningPolicy)
        }else if let product=interpretation.plan.productDecision {
            plan=try ExhaustiveAppointmentPlanner.compile(product,input:input,policy:interpretation.plan.planningPolicy)
        }else{plan=try ExhaustiveAppointmentPlanner.compile(interpretation.plan.receipt,input:input,policy:interpretation.plan.planningPolicy)}
        try Task.checkCancellation()
        let permit=try await store.permit(),inventory=try await store.recordInventory(permit:permit)
        try Task.checkCancellation();try await store.validate(permit)
        self.interpretation=interpretation
        return try install(inventory:inventory,plan:plan,requestID:requestID)
    }
    private func install(inventory:RecordInventory,plan:ExhaustiveAppointmentPlan,requestID:UUID)throws->ExhaustiveAppointmentAnswer {
        self.inventory=inventory;self.plan=plan;self.requestID=requestID
        for reading in inventory.sourceReadings where reading.warning != nil {
            addTarget(reading.source,recordID:nil,fields:[],reason:.sourceReading)
        }
        for source in inventory.unlinkedSources.union(inventory.pendingSourcePreparations) {addTarget(source,recordID:nil,fields:[],reason:.sourcePreparation)}
        return try snapshot()
    }

    /// maximumRecords is a work budget, never a result limit. Repeated calls
    /// eventually visit every identity from the original snapshot in order.
    public func advance(activeRequestID:UUID,maximumRecords:Int=256)async throws->ExhaustiveAppointmentAnswer {
        guard !busy else{throw SemanticError.existingAttempt}
        guard let inventory,let plan,requestID==activeRequestID else{throw MemoryError.invalidContext}
        guard (1...4096).contains(maximumRecords)else{throw MemoryError.unsupportedQuery}
        busy=true;defer{busy=false}
        try await store.validate(inventory.permit)
        let end=min(inventory.recordIDs.count,offset+maximumRecords)
        while offset<end {
            try Task.checkCancellation()
            let next=min(end,offset+128),ids=Set(inventory.recordIDs[offset..<next])
            let page=try await store.recordSearchSnapshot(permit:inventory.permit,recordIDs:ids)
            try Task.checkCancellation()
            for record in page.records {evaluate(record,plan:plan)}
            offset=next;generation+=1
        }
        try await store.validate(inventory.permit)
        return try snapshot()
    }
    public func current(activeRequestID:UUID)async throws->ExhaustiveAppointmentAnswer {
        guard !busy,requestID==activeRequestID,let inventory else{throw MemoryError.invalidContext}
        try await store.validate(inventory.permit);return try snapshot()
    }
    @discardableResult public func admit(_ answer:ExhaustiveAppointmentAnswer,activeRequestID:UUID)async throws->ExhaustiveAppointmentAnswer {
        guard !busy,answer.owner==identity,answer.requestID==activeRequestID,requestID==activeRequestID,answer.generation==generation,let inventory else{throw MemoryError.staleResult}
        try await store.validate(inventory.permit);return answer
    }

    /// Source-local unit projection. The supplied group members must cover the
    /// ENTIRE scanned inventory, not just top matches or one photo of a library.
    /// Global multi-source occurrence identity needs a separate contract.
    public func sourceUnitAnswer(_ answer:ExhaustiveAppointmentAnswer,request:SourceOccurrenceRequest,
        relationTask:ChoiceTask?=nil,relationReceipt:DecisionReceipt?=nil,activeRequestID:UUID)async throws->SourceUnitQueryAnswer {
        _=try await admit(answer,activeRequestID:activeRequestID)
        guard let inventory,answer.plan.resultUnit != nil,answer.coverage.entireAdmittedInventory else{throw MemoryError.invalidContext}
        let members=try request.checkedMembers(),ids=Set(members.map{$0.projection.recordID})
        guard ids==Set(inventory.recordIDs) else{throw SemanticError.unresolved("Source-local unit proof does not cover the entire query inventory")}
        busy=true;defer{busy=false}
        let current=try await store.recordSearchSnapshot(permit:inventory.permit,recordIDs:ids)
        guard Set(current.records.map{$0.projection.recordID})==ids else{throw MemoryError.staleResult}
        for member in members {
            guard current.records.first(where:{$0.projection.recordID==member.projection.recordID})?.projection==member.projection else{throw MemoryError.staleResult}
        }
        let sources=try await store.sourceSearchSnapshot(permit:inventory.permit)
        guard sources.sources.contains(request.source) else{throw MemoryError.staleResult}
        let proposal:SourceOccurrenceProposal?
        if answer.plan.resultUnit == .occurrences {
            guard let relationTask,let relationReceipt else{throw SemanticError.unresolved("Occurrence query requires actual current relation receipt")}
            proposal=try SourceOccurrenceInterpreter.compile(request,task:relationTask,receipt:relationReceipt)
        }else{
            guard relationTask==nil,relationReceipt==nil else{throw SemanticError.unsupportedEvidence}
            proposal=nil
        }
        let result=try SourceUnitQueryProjection.project(answer,request:request,proposal:proposal)
        try await store.validate(inventory.permit)
        return result
    }
    @discardableResult public func admitSourceUnitAnswer(_ answer:SourceUnitQueryAnswer,activeRequestID:UUID)async throws->SourceUnitQueryAnswer {
        _=try await admit(answer.recordAnswer,activeRequestID:activeRequestID);return answer
    }

    /// Global inventory composition with proof for every source and member.
    /// Cross-photo relations are never inferred by adding source-local counts.
    public func inventoryUnitAnswer(_ answer:ExhaustiveAppointmentAnswer,prepared:PreparedInventoryUnits,
        relationTask:ChoiceTask?=nil,relationReceipt:DecisionReceipt?=nil,documentIdentityPolicy:InventoryDocumentIdentityPolicy = .sourceLocalV1,activeRequestID:UUID)async throws->InventoryUnitQueryAnswer {
        _=try await admit(answer,activeRequestID:activeRequestID)
        guard let inventory,answer.plan.resultUnit==prepared.resultUnit,answer.coverage.entireAdmittedInventory,
              documentIdentityPolicy == .sourceLocalV1 || prepared.resultUnit == .documents,
              [.list,.count,.sourceEvidence].contains(answer.plan.operation) else{throw MemoryError.invalidContext}
        let members=prepared.units.flatMap(\.members),ids=Set(members.map{$0.projection.recordID})
        guard ids==Set(inventory.recordIDs) else{throw SemanticError.unresolved("Unit evidence must cover the entire current inventory")}
        busy=true;defer{busy=false}
        for start in stride(from:0,to:members.count,by:128) {
            let page=Array(members[start..<min(start+128,members.count)]),pageIDs=Set(page.map{$0.projection.recordID})
            let current=try await store.recordSearchSnapshot(permit:inventory.permit,recordIDs:pageIDs)
            guard current.records.count==page.count else{throw MemoryError.staleResult}
            for member in page {guard current.records.first(where:{$0.projection.recordID==member.projection.recordID})?.projection==member.projection else{throw MemoryError.staleResult}}
        }
        let sources=try await store.sourceSearchSnapshot(permit:inventory.permit)
        guard prepared.sources.allSatisfy({sources.sources.contains($0)}) else{throw MemoryError.staleResult}
        let units:[SourceOccurrenceUnit],resolved:Bool
        if prepared.resultUnit == .documents {
            if documentIdentityPolicy == .crossSourceV1 && prepared.sources.count > 1 {
                guard let relationTask,let relationReceipt else{throw SemanticError.unresolved("Cross-source document identity proof is required")}
                let proposal=try InventoryDocumentIdentityInterpreter.compile(id:relationTask.id,prepared:prepared,task:relationTask,receipt:relationReceipt)
                units=proposal.units;resolved=proposal.identityResolved
            }else{
                guard relationTask==nil,relationReceipt==nil else{throw SemanticError.unsupportedEvidence}
                // Separate photos may show the same document; native IDs alone
                // are not cross-photo document identity proof.
                units=prepared.units;resolved=prepared.identityResolved
            }
        }else if !prepared.identityResolved {
            guard relationTask==nil,relationReceipt==nil else{throw SemanticError.unsupportedEvidence}
            units=prepared.units;resolved=false
        }else if prepared.sources.count==1 {
            guard relationTask==nil,relationReceipt==nil else{throw SemanticError.unsupportedEvidence}
            units=prepared.units;resolved=true
        }else{
            guard let relationTask,let relationReceipt else{throw SemanticError.unresolved("Cross-source occurrence identity proof is required")}
            let proposal=try InventoryOccurrenceInterpreter.compile(id:relationTask.id,prepared:prepared,task:relationTask,receipt:relationReceipt)
            units=proposal.units;resolved=proposal.identityResolved
        }
        let e=SourceUnitQueryProjection.evaluate(answer,units:units,identityResolved:resolved)
        let result=InventoryUnitQueryAnswer(resultUnit:prepared.resultUnit,matchingUnits:e.matched,uncertainUnits:e.uncertain,excludedUnits:e.excluded,unresolvedFieldsByUnit:e.gaps,identityResolved:resolved,coverage:answer.coverage,queryReceipt:answer.plan.receipt,sourceReceipts:prepared.sourceReceipts,localRelationReceipts:prepared.localRelationReceipts,crossSourceRelationReceipt:relationReceipt,evidenceBindingSHA256:prepared.bindingSHA256,recordAnswer:answer)
        try await store.validate(inventory.permit);return result
    }
    @discardableResult public func admitInventoryUnitAnswer(_ answer:InventoryUnitQueryAnswer,activeRequestID:UUID)async throws->InventoryUnitQueryAnswer {
        _=try await admit(answer.recordAnswer,activeRequestID:activeRequestID);return answer
    }

    /// Call after actual publication. The order may differ from preparation,
    /// but must contain every displayed matching/uncertain unit exactly once.
    public func contextForDisplayedSourceUnitAnswer(_ answer:SourceUnitQueryAnswer,
        activeRequestID:UUID,displayedUnitIDs:[String],displayIdentity:UUID?=nil)async throws->DisplayedUnitContext {
        _=try await admitSourceUnitAnswer(answer,activeRequestID:activeRequestID)
        return try installUnitContext(answer.recordAnswer,unit:answer.resultUnit,units:answer.orderedUnits,
            uncertain:Set(answer.uncertainUnits.map(\.id)),identityResolved:answer.identityResolved,
            displayedUnitIDs:displayedUnitIDs,displayIdentity:displayIdentity,proof:DisplayedUnitProof(queryReceipt:answer.queryReceipt,
                sourceReceipts:[answer.groupingReceipt],localRelationReceipts:answer.relationReceipt.map{[$0]} ?? [],crossSourceRelationReceipt:nil))
    }
    public func contextForDisplayedInventoryUnitAnswer(_ answer:InventoryUnitQueryAnswer,
        activeRequestID:UUID,displayedUnitIDs:[String],displayIdentity:UUID?=nil)async throws->DisplayedUnitContext {
        _=try await admitInventoryUnitAnswer(answer,activeRequestID:activeRequestID)
        return try installUnitContext(answer.recordAnswer,unit:answer.resultUnit,units:answer.orderedUnits,
            uncertain:Set(answer.uncertainUnits.map(\.id)),identityResolved:answer.identityResolved,
            displayedUnitIDs:displayedUnitIDs,displayIdentity:displayIdentity,proof:DisplayedUnitProof(queryReceipt:answer.queryReceipt,
                sourceReceipts:answer.sourceReceipts,localRelationReceipts:answer.localRelationReceipts,
                crossSourceRelationReceipt:answer.crossSourceRelationReceipt))
    }
    private func installUnitContext(_ answer:ExhaustiveAppointmentAnswer,unit:AppointmentResultUnit,
        units:[SourceOccurrenceUnit],uncertain:Set<String>,identityResolved:Bool,
        displayedUnitIDs:[String],displayIdentity:UUID?,proof:DisplayedUnitProof)throws->DisplayedUnitContext {
        guard !busy,answer.coverage.entireAdmittedInventory,let interpretation,
              displayedUnitIDs.count==units.count,Set(displayedUnitIDs).count==units.count,
              Set(displayedUnitIDs)==Set(units.map(\.id)) else{throw MemoryError.invalidContext}
        let match=Set(answer.matches.map{$0.projection.recordID}),unknown=Set(answer.uncertain.map{$0.projection.recordID})
        let byID=Dictionary(uniqueKeysWithValues:units.map{($0.id,$0)})
        let rows=displayedUnitIDs.map { id in
            let u=byID[id]!
            return DisplayedUnitEvidenceRow(unit:u,membershipUncertain:uncertain.contains(id),
                memberSelection:Dictionary(uniqueKeysWithValues:u.members.map { member in
                    let id=member.projection.recordID
                    return(id,match.contains(id) ? UnitEvidenceMemberSelection.matching:unknown.contains(id) ? .uncertain:.excluded)
                }))
        }
        // A replica may use the same display label only after reconstructing
        // the entire admitted answer. Labels never import evidence authority.
        let id=displayIdentity ?? UUID(),input=interpretation.input
        guard !installedDisplayedUnitIDs.contains(id) else{throw MemoryError.invalidContext}
        let binding=try DisplayedUnitBinding.data(id:id,answer:answer,question:input.question,
            submittedAt:input.now,resultUnit:unit,rows:rows,identityResolved:identityResolved,proof:proof)
        let context=DisplayedUnitContext(id:id,answerRequestID:answer.requestID,originalQuestion:input.question,
            originalSubmittedAt:input.now,resultUnit:unit,orderedRows:rows,identityResolved:identityResolved,
            coverage:answer.coverage,proof:proof,bindingSHA256:ChoiceTask.hash(binding),recordAnswer:answer)
        installedDisplayedUnitIDs.insert(id);displayedUnitContextID=id;return context
    }
    @discardableResult public func admitDisplayedUnitContext(_ context:DisplayedUnitContext,
        activeAnswerRequestID:UUID)async throws->DisplayedUnitContext {
        guard displayedUnitContextID==context.id else{throw MemoryError.staleResult}
        _=try await admit(context.recordAnswer,activeRequestID:activeAnswerRequestID)
        // Recheck after await: another publication may have replaced the context.
        guard displayedUnitContextID==context.id else{throw MemoryError.staleResult}
        return context
    }
    /// Native Home/dismissal/new-answer handling clears the exact old display.
    /// A delayed dismissal cannot clear a newer context by accident.
    public func clearDisplayedUnitContext(_ contextID:UUID)throws {
        guard displayedUnitContextID==contextID else{throw MemoryError.staleResult}
        displayedUnitContextID=nil
    }
    public func selectDisplayedUnit(_ context:DisplayedUnitContext,ordinal:Int,
        activeAnswerRequestID:UUID)async throws->DisplayedUnitSelection {
        _=try await admitDisplayedUnitContext(context,activeAnswerRequestID:activeAnswerRequestID)
        guard ordinal>0,ordinal<=context.orderedRows.count else{throw MemoryError.invalidOrdinal}
        return DisplayedUnitSelection(contextID:context.id,ordinal:ordinal,row:context.orderedRows[ordinal-1],proof:context.proof,context:context)
    }
    public func selectDisplayedUnit(_ context:DisplayedUnitContext,unitID:String,
        activeAnswerRequestID:UUID)async throws->DisplayedUnitSelection {
        guard let index=context.orderedRows.firstIndex(where:{$0.unit.id==unitID}) else{throw MemoryError.invalidContext}
        return try await selectDisplayedUnit(context,ordinal:index+1,activeAnswerRequestID:activeAnswerRequestID)
    }
    @discardableResult public func admitDisplayedUnitSelection(_ selection:DisplayedUnitSelection,
        activeAnswerRequestID:UUID)async throws->DisplayedUnitSelection {
        _=try await admitDisplayedUnitContext(selection.context,activeAnswerRequestID:activeAnswerRequestID);return selection
    }
    public func prepareDisplayedUnitFollowup(_ input:EvidenceQuestionInput,context:DisplayedUnitContext,
        activeAnswerRequestID:UUID)async throws->PreparedDisplayedUnitFollowup {
        _=try await admitDisplayedUnitContext(context,activeAnswerRequestID:activeAnswerRequestID)
        let task=try DisplayedUnitFollowupInterpreter.task(input,context:context)
        return PreparedDisplayedUnitFollowup(task:task,input:input,context:context)
    }
    public func completeDisplayedUnitFollowup(_ receipt:DecisionReceipt,for prepared:PreparedDisplayedUnitFollowup,
        activeAnswerRequestID:UUID)async throws->DisplayedUnitFollowup {
        try await finishUnitFollowup(DecisionChoiceView(original:receipt),prepared:prepared,activeAnswerRequestID:activeAnswerRequestID)
    }
    /// Consume the actual unified receipt without fabricating a child receipt.
    public func completeDisplayedUnitFollowup(_ decision:CompiledProductQuestion,for prepared:PreparedDisplayedUnitFollowup,
        activeAnswerRequestID:UUID)async throws->DisplayedUnitFollowup {
        try await decision.validateCurrentAuthority(in:store)
        return try await finishUnitFollowup(decision.choices(for:prepared.task,route:.contextual),prepared:prepared,activeAnswerRequestID:activeAnswerRequestID)
    }
    public func completeDisplayedUnitFollowup(compactDecision:CompiledCompactProductQuestion,for prepared:PreparedDisplayedUnitFollowup,
        activeAnswerRequestID:UUID)async throws->DisplayedUnitFollowup {
        try await compactDecision.validateCurrentAuthority(in:store)
        return try await finishUnitFollowup(compactDecision.choices(for:prepared.task,route:.contextual),prepared:prepared,activeAnswerRequestID:activeAnswerRequestID)
    }
    private func finishUnitFollowup(_ receipt:DecisionChoiceView,prepared:PreparedDisplayedUnitFollowup,
        activeAnswerRequestID:UUID)async throws->DisplayedUnitFollowup {
        _=try await admitDisplayedUnitContext(prepared.context,activeAnswerRequestID:activeAnswerRequestID)
        let intent=try DisplayedUnitFollowupInterpreter.compile(receipt,prepared:prepared)
        let selection=try await selectDisplayedUnit(prepared.context,ordinal:intent.ordinal,activeAnswerRequestID:activeAnswerRequestID)
        return DisplayedUnitFollowup(selection:selection,operation:intent.operation,requestedSourceEvidence:intent.facets,
            originalReceipt:receipt.original,prepared:prepared)
    }
    @discardableResult public func admitDisplayedUnitFollowup(_ answer:DisplayedUnitFollowup,
        activeAnswerRequestID:UUID)async throws->DisplayedUnitFollowup {
        _=try await admitDisplayedUnitSelection(answer.selection,activeAnswerRequestID:activeAnswerRequestID);return answer
    }

    /// Bind follow-up references to the complete list the host actually displayed.
    /// Call only after native publication; the host must keep this answer's active
    /// identity and recheck its own current sources. This grants no photo access.
    /// The supported display order is matches followed by uncertain candidates.
    /// Contextual questions retain their existing 256-record inventory bound:
    /// larger inventories refuse here, never silently truncate an exhaustive result.
    public func contextForDisplayedAnswer(_ answer:ExhaustiveAppointmentAnswer,
        activeRequestID:UUID,displayedRecordIDs:[String])async throws->EvidenceQuestionContext {
        guard answer.plan.resultUnit == nil else{throw MemoryError.unsupportedQuery}
        guard !busy,answer.owner==identity,answer.requestID==activeRequestID,
              requestID==activeRequestID,answer.generation==generation,
              let inventory,let interpretation,answer.coverage.entireAdmittedInventory else {
            throw MemoryError.staleResult
        }
        guard [.list,.count,.sourceEvidence].contains(answer.plan.operation),
              interpretation.input.recordScope == .inventory else {throw SemanticError.unsupportedEvidence}
        let ordered=answer.matches+answer.uncertain
        guard displayedRecordIDs==ordered.map({$0.projection.recordID}) else {throw MemoryError.invalidContext}
        busy=true;defer{busy=false}
        let snapshot=try await store.recordSearchSnapshot(permit:inventory.permit,maximumRecords:256)
        let current=Dictionary(uniqueKeysWithValues:snapshot.records.map{($0.projection.recordID,$0)})
        guard ordered.allSatisfy({current[$0.projection.recordID]==$0}) else {throw MemoryError.staleResult}
        try await store.validate(snapshot.permit)
        // Uncertain membership must not become a definite match merely because
        // a later question asks where it is or retains the displayed subset.
        let issues=Dictionary(uniqueKeysWithValues:answer.uncertain.map {
            ($0.projection.recordID,["priorMembershipUnresolved"])
        })
        return EvidenceQuestionContext(answerID:UUID(),selectedOrdinal:nil,pendingQuestion:nil,
            orderedRecordIDs:displayedRecordIDs,orderedTitles:ordered.map{$0.projection.appointment.displayTitle},
            snapshot:snapshot,window:answer.plan.window,submittedAt:interpretation.input.now,
            calendar:interpretation.input.calendar,predicateIssues:issues,
            startClockMeaning:answer.plan.clock,literalPredicates:answer.plan.predicates,recordScope:.inventory)
    }
    private func addTarget(_ source:SourceReference,recordID:String?,fields:Set<RequestedAppointmentDetail>,reason:MissingEvidenceReason) {
        let old=targets[source]
        targets[source]=MissingEvidenceTarget(source:source,recordIDs:(old?.recordIDs ?? []).union(recordID.map{[$0]} ?? []),fields:(old?.fields ?? []).union(fields),reasons:(old?.reasons ?? []).union([reason]))
    }
    private func evaluate(_ row:StoredMemory,plan:ExhaustiveAppointmentPlan) {
        let a=row.projection.appointment,d=a.date,id=row.projection.recordID
        if plan.status != "all",a.status.rawValue != plan.status{return}
        if plan.kind != "all",a.kind.rawValue != plan.kind{return}
        if plan.clock.isRestricted,plan.clock.lowerMinute>plan.clock.upperMinute{return}
        let literal=EvidenceTextPredicate.evaluateAll(plan.predicates,in:a)
        if literal==false{return}
        let membership=EvidenceQuestionSession.assess(d,window:plan.window,inferredPolicy:plan.inferredDatePolicy)
        if membership == .outside{return}
        var missing=Set<RequestedAppointmentDetail>(),unknown=literal==nil || membership == .unresolved
        if literal==nil {
            for predicate in plan.predicates where predicate.evaluate(a)==nil {
                if let field=RequestedAppointmentDetail(rawValue:predicate.field.rawValue){missing.insert(field)}
            }
        }
        if membership == .unresolved {missing.insert(.localDate);if !plan.window.printedCalendar{missing.formUnion([.startClock,.explicitTimeZone])}}
        if plan.clock.isRestricted {
            if d.certainty != .conflicting,let h=d.hour,let m=d.minute,(0...23).contains(h),(0...59).contains(m) {
                if !plan.clock.contains(h*60+m){return}
            }else{unknown=true;missing.insert(.startClock)}
        }
        if plan.requestedSourceEvidence.contains(.documentedStatus) {
            let hasObservedCancellation=a.status == .cancelled && row.projection.support.contains{$0.field == .status && $0.origin == .observed && !$0.anchors.isEmpty}
            if !hasObservedCancellation {
                for source in row.projection.sources {addTarget(source,recordID:id,fields:[],reason:.statusEvidence)}
            }
        }
        let conditionGaps=missing
        for field in plan.requestedDetails where !Self.has(field,in:a){missing.insert(field)}
        if plan.operation == .earliest || plan.operation == .latest {
            if case .uncertain=NativeDates.resolve(d,inferredPolicy:plan.inferredDatePolicy) {
                for field in [RequestedAppointmentDetail.localDate,.startClock,.explicitTimeZone] where !Self.has(field,in:a){missing.insert(field)}
                // DST ambiguity or invalid zone must remain visible even when
                // all scalar components are present.
                if missing.isEmpty{missing.insert(.explicitTimeZone)}
            }
        }
        if !missing.isEmpty {
            details[id]=missing
            for source in row.projection.sources {
                addTarget(source,recordID:id,fields:missing,reason:conditionGaps.isEmpty ? .requestedDetail:.queryCondition)
            }
        }
        if unknown{uncertain.append(row)}else{matched.append(row)}
    }
    private static func has(_ field:RequestedAppointmentDetail,in a:AppointmentProjection)->Bool {
        func text(_ value:String?)->Bool {value?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty==false}
        let d=a.date
        switch field {
        case .performer:return text(a.performer)
        case .provider:return text(a.provider)
        case .venue:return text(a.venue)
        case .venueAddress:return text(a.venueAddress)
        case .startClock:return d.certainty != .conflicting && d.hour.map{(0...23).contains($0)}==true && d.minute.map{(0...59).contains($0)}==true
        case .explicitTimeZone:return d.certainty != .conflicting && (d.timeZoneID.flatMap(TimeZone.init(identifier:)) != nil || d.utcOffsetSeconds.map{(-43200...50400).contains($0)}==true)
        case .localDate:
            guard d.certainty == .explicit,let y=d.year,let m=d.month,let day=d.day else{return false}
            var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(secondsFromGMT:0)!
            let parts=DateComponents(year:y,month:m,day:day)
            return c.date(from:parts).map{c.dateComponents([.year,.month,.day],from:$0)==parts} ?? false
        }
    }
    private func snapshot()throws->ExhaustiveAppointmentAnswer {
        guard let inventory,let plan,let requestID,let interpretation else{throw MemoryError.invalidContext}
        let coverage=ExhaustiveAppointmentCoverage(totalRecords:inventory.recordIDs.count,inspectedRecords:offset,unknownMembershipRecords:uncertain.count,unprojectedRecords:inventory.unprojectedRecordIDs.count,unlinkedSources:inventory.unlinkedSources.count,sourcesWithReadingGaps:inventory.sourceReadings.filter{$0.warning != nil}.count,pendingSourcePreparations:inventory.pendingSourcePreparations.count)
        var extremes:[StoredMemory]?
        if coverage.membershipComplete && (plan.operation == .earliest || plan.operation == .latest) {
            let dates=matched.compactMap{row->(StoredMemory,Date)? in
                if case .instant(let date)=NativeDates.resolve(row.projection.appointment.date,inferredPolicy:plan.inferredDatePolicy){return (row,date)};return nil
            }
            if dates.count==matched.count {
                let value=plan.operation == .earliest ? dates.map(\.1).min():dates.map(\.1).max()
                extremes=dates.filter{$0.1==value}.map(\.0)
            }
        }
        return ExhaustiveAppointmentAnswer(interpretation:interpretation,requestID:requestID,plan:plan,matches:matched,uncertain:uncertain,unresolvedDetails:details,rereadTargets:targets.values.sorted{$0.source.id<$1.source.id},coverage:coverage,extremeRecords:extremes,owner:identity,generation:generation)
    }
}

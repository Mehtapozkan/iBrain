import Foundation
import IBrain
import IBrainSemantics

public struct LinkedContextBudget:Sendable {
    public let maximumDepth:Int,maximumReads:Int,maximumSources:Int,maximumPayloadBytes:Int,maximumSummaryBytes:Int
    public init(maximumDepth:Int=2,maximumReads:Int=12,maximumSources:Int=12,maximumPayloadBytes:Int=65536,maximumSummaryBytes:Int=16384) {
        self.maximumDepth=maximumDepth;self.maximumReads=maximumReads;self.maximumSources=maximumSources
        self.maximumPayloadBytes=maximumPayloadBytes;self.maximumSummaryBytes=maximumSummaryBytes
    }
}
public enum LinkedContextError:Error,Equatable {case staleReference,invalidBinding,budgetExceeded,unavailableEvidence,wrongSelection}
public enum LinkedEvidenceKind:String,Codable,Sendable {case appointmentFacts,retainedChange,worldEntity}
/// Codable metadata is NOT authority. Expansion requires the original opaque
/// prepared request and an exactly matching session-issued reference.
public struct LinkedEvidenceReference:Codable,Equatable,Sendable {
    public let id:UUID
    public let kind:LinkedEvidenceKind
    public let recordID:String
    public let recordRevision:Int
    public let sources:[SourceReference]
    public let labelPreview:String
    public let labelTruncated:Bool
    public let depth:Int
    public let via:WorldPredicate?
}
public struct LinkedContextIssue:Codable,Equatable,Sendable {
    public let recordID:String
    public let reason:String
    public let targetID:String?
}
public struct LinkedAppointmentBinding:Sendable {
    public let recordID:String
    public let worldEventID:String?
    public init(recordID:String,worldEventID:String?=nil){self.recordID=recordID;self.worldEventID=worldEventID}
}
public struct LinkedAppointmentSummary:Codable,Sendable {
    public let recordID:String
    public let titlePreview:String
    public let titleTruncated:Bool
    public let date:EventDate
    public let status:AppointmentStatus
    public let reference:LinkedEvidenceReference
    public let nextHops:[LinkedEvidenceReference]
    public let hasRetainedChange:Bool
}
public struct PreparedLinkedAppointmentContext:Sendable {
    public let requestID:UUID
    public let summaries:[LinkedAppointmentSummary]
    public let issues:[LinkedContextIssue]
    public let entireAdmittedInventory:Bool
    public let sourcesWithReadingWarnings:Int
    public let pendingSources:Int
    fileprivate let owner:UUID
    fileprivate let generation:Int
    fileprivate let permit:SnapshotPermit
}
public struct LinkedDisplayedContext:Sendable {
    public let id:UUID
    public let orderedRecordIDs:[String]
    fileprivate let prepared:PreparedLinkedAppointmentContext
}
public struct LinkedRecordSelection:Sendable {
    public let recordID:String
    fileprivate let displayID:UUID
    fileprivate let prepared:PreparedLinkedAppointmentContext
}
public enum LinkedEvidencePayload:Codable,Sendable {
    case appointment(MemoryProjection)
    case change(RecordChangeExplanation)
    case world(WorldAnswerItem)
}
public struct LinkedEvidenceExpansion:Codable,Sendable {
    public let reference:LinkedEvidenceReference
    public let rootRecordID:String
    public let payload:LinkedEvidencePayload
    /// Real admitted edge claims, including quoted support, never a name-based join.
    public let traversalEvidence:[WorldClaim]
    public let nextHops:[LinkedEvidenceReference]
    public let issues:[LinkedContextIssue]
}
public struct LinkedContextMetrics:Codable,Sendable {
    public let evidenceReadAttempts:Int
    public let preparationRecordsRead:Int
    public let headerRecordsRead:Int
    public let distinctExpandedSources:Int
    public let expandedPayloadBytes:Int
    public let summaryBytes:Int
    public let modelCalls:Int
}
public struct LinkedContextSnapshot:Sendable {
    public let expansions:[LinkedEvidenceExpansion]
    public let outstandingReferences:[LinkedEvidenceReference]
    public let metrics:LinkedContextMetrics
    public let allRequestedReferencesExpanded:Bool
    public var personalCalendarComplete:Bool {false}
}

/// Opt-in derived context only. Existing Pin domain/source/world pins remain
/// authoritative; the native change and field engines supply every value.
public actor LinkedAppointmentContextSession {
    private struct Authorized:Sendable {
        let reference:LinkedEvidenceReference
        let root:String
        let visited:Set<String>
        let path:[WorldClaim]
    }
    private let store:MemoryStore,budget:LinkedContextBudget,identity=UUID()
    private var generation=0,activeRequest:UUID?,busy=false,displayID:UUID?
    private var references:[UUID:Authorized]=[:],expanded:[UUID:LinkedEvidenceExpansion]=[:]
    private var expandedSelectors:[UUID:([WorldPredicate],Set<AppointmentField>?)]=[:]
    private var reads=0,preparationReads=0,headers=0,payloadBytes=0,summaryBytes=0,sources=Set<SourceReference>()
    public init(store:MemoryStore,budget:LinkedContextBudget=LinkedContextBudget())throws {
        guard (0...4).contains(budget.maximumDepth),(1...128).contains(budget.maximumReads),(1...128).contains(budget.maximumSources),
              (256...1_048_576).contains(budget.maximumPayloadBytes),(256...262144).contains(budget.maximumSummaryBytes)else{throw LinkedContextError.budgetExceeded}
        self.store=store;self.budget=budget
    }
    private func sorted(_ refs:Set<SourceReference>)->[SourceReference]{refs.sorted{($0.id,$0.revision,$0.fingerprint)<($1.id,$1.revision,$1.fingerprint)}}
    private func preview(_ text:String)->(String,Bool){(String(text.prefix(160)),text.count>160)}
    private func issue(_ id:String,_ reason:String,_ target:String?=nil)->LinkedContextIssue{.init(recordID:id,reason:reason,targetID:target)}
    private func encoded<T:Encodable>(_ v:T)throws->Int {try JSONEncoder().encode(v).count}
    private func register(kind:LinkedEvidenceKind,id:String,revision:Int,sources:Set<SourceReference>,label:String,depth:Int,via:WorldPredicate?,root:String,visited:Set<String>,path:[WorldClaim])throws->LinkedEvidenceReference {
        if let old=references.values.first(where:{$0.root==root && $0.reference.kind==kind && $0.reference.recordID==id && $0.reference.recordRevision==revision && Set($0.reference.sources)==sources && $0.reference.depth==depth && $0.reference.via==via && $0.visited==visited && $0.path==path}) {return old.reference}
        guard references.count<256 else{throw LinkedContextError.budgetExceeded}
        let p=preview(label),ref=LinkedEvidenceReference(id:UUID(),kind:kind,recordID:id,recordRevision:revision,sources:sorted(sources),labelPreview:p.0,labelTruncated:p.1,depth:depth,via:via)
        references[ref.id]=Authorized(reference:ref,root:root,visited:visited,path:path);return ref
    }
    private func validate(_ p:PreparedLinkedAppointmentContext,requestID:UUID)async throws {
        guard p.owner==identity,p.generation==generation,p.requestID==requestID,activeRequest==requestID else{throw LinkedContextError.staleReference}
        try await store.validate(p.permit)
        guard p.generation==generation,activeRequest==requestID else{throw LinkedContextError.staleReference}
        try Task.checkCancellation()
    }
    public func cancel() {generation+=1;activeRequest=nil;displayID=nil;references=[:];expanded=[:];expandedSelectors=[:]}

    public func prepare(bindings:[LinkedAppointmentBinding],requestID:UUID)async throws->PreparedLinkedAppointmentContext {
        guard !busy else{throw SemanticError.existingAttempt};busy=true;defer{busy=false}
        guard !bindings.isEmpty,bindings.count<=64,Set(bindings.map(\.recordID)).count==bindings.count else{throw LinkedContextError.invalidBinding}
        cancel();activeRequest=requestID;let epoch=generation,permit=try await store.permit()
        references=[:];expanded=[:];reads=0;preparationReads=0;headers=0;payloadBytes=0;summaryBytes=0;sources=[]
        func current()throws{guard activeRequest==requestID,generation==epoch else{throw LinkedContextError.staleReference};try Task.checkCancellation()}
        let ids=Set(bindings.map(\.recordID))
        let records=try await store.recordSearchSnapshot(permit:permit,recordIDs:ids),changes=try await store.sourceChangeSnapshot(permit:permit)
        let inventory=try await store.recordInventory(permit:permit);try current()
        guard Set(records.records.map{$0.projection.recordID})==ids else{throw LinkedContextError.unavailableEvidence}
        preparationReads=records.records.count+changes.count
        var summaries:[LinkedAppointmentSummary]=[],issues:[LinkedContextIssue]=[]
        for binding in bindings {
            try current();let p=records.records.first{$0.projection.recordID==binding.recordID}!.projection
            let root=try register(kind:.appointmentFacts,id:p.recordID,revision:p.recordRevision,sources:p.sources,label:p.appointment.displayTitle,depth:0,via:nil,root:p.recordID,visited:[],path:[])
            var next:[LinkedEvidenceReference]=[]
            if let change=changes.first(where:{$0.recordID==p.recordID && $0.current==p}) {
                next.append(try register(kind:.retainedChange,id:p.recordID,revision:p.recordRevision,sources:change.sources,label:"Retained changes: "+p.appointment.displayTitle,depth:0,via:nil,root:p.recordID,visited:[],path:[]))
            }
            if let eventID=binding.worldEventID {
                let event=try await store.linkedWorldEvidence(recordID:eventID,requested:[.name,.status,.category,.scheduledAt,.locatedAt,.performedBy],permit:permit);preparationReads+=1;try current()
                let all=event.fields.flatMap(\.claims)
                func target(_ predicate:WorldPredicate)->String? {
                    let targets=Set(all.filter{$0.predicate==predicate && $0.origin != .inferred}.compactMap{if case .entity(let id)=$0.value{return id};return nil})
                    return targets.count==1 ? targets.first:nil
                }
                let identities=AppointmentWorldIdentities(eventID:eventID,venueID:p.appointment.venue==nil ? nil:target(.locatedAt),performerID:p.appointment.performer==nil ? nil:target(.performedBy),revision:p.recordRevision)
                let expected=try AppointmentWorldCompiler.compile(p,identities:identities,policy:.typedTemporalValuesV2).first{$0.recordID==eventID}!
                guard expected.claims.allSatisfy({e in all.contains{c in c.predicate==e.predicate && c.value==e.value && c.origin==e.origin && c.anchors.count==e.anchors.count && e.anchors.allSatisfy{c.anchors.contains($0)}}})else{throw LinkedContextError.invalidBinding}
                let result=try await nextHops(from:event,depth:0,root:p.recordID,visited:[eventID],path:[],permit:permit)
                next+=result.0;issues+=result.1;try current()
            }
            let title=preview(p.appointment.displayTitle)
            summaries.append(.init(recordID:p.recordID,titlePreview:title.0,titleTruncated:title.1,date:p.appointment.date,status:p.appointment.status,reference:root,nextHops:next,hasRetainedChange:next.contains{$0.kind == .retainedChange}))
        }
        summaryBytes=try encoded(summaries)
        guard summaryBytes<=budget.maximumSummaryBytes else{throw LinkedContextError.budgetExceeded}
        try await store.validate(permit);try current()
        return PreparedLinkedAppointmentContext(requestID:requestID,summaries:summaries,issues:issues,entireAdmittedInventory:Set(inventory.recordIDs)==ids,
            sourcesWithReadingWarnings:inventory.sourceReadings.filter{$0.warning != nil}.count,pendingSources:inventory.pendingSourcePreparations.count,owner:identity,generation:epoch,permit:permit)
    }
    private func nextHops(from item:WorldAnswerItem,depth:Int,root:String,visited:Set<String>,path:[WorldClaim],permit:SnapshotPermit)async throws->([LinkedEvidenceReference],[LinkedContextIssue]) {
        let relationshipFields=item.fields.filter{$0.predicate.isRelationship}
        let claims=relationshipFields.flatMap(\.claims)
        let ids=Set(claims.compactMap{if case .entity(let id)=$0.value{return id};return nil})
        let found=try await store.linkedWorldHeaders(recordIDs:ids,permit:permit);headers+=ids.count
        var refs:[LinkedEvidenceReference]=[],issues:[LinkedContextIssue]=[]
        for claim in claims {
            guard case .entity(let id)=claim.value else{continue}
            guard claim.origin != .inferred,relationshipFields.first(where:{$0.predicate==claim.predicate})?.state == .known else{issues.append(issue(root,"uncertainRelationship",id));continue}
            guard let target=found.first(where:{$0.recordID==id})else{issues.append(issue(root,"unavailableTarget",id));continue}
            guard claim.origin == .domainCorrection || target.identifyingClaims.contains(where:{identity in !identity.anchors.isEmpty && identity.anchors.allSatisfy{a in claim.anchors.contains{$0.source==a.source && $0.observationID==a.observationID && $0.quote.contains(a.quote)}}})else{issues.append(issue(root,"targetIdentityNotQuoted",id));continue}
            guard depth<budget.maximumDepth else{issues.append(issue(root,"depthLimit",id));continue}
            guard !visited.contains(id)else{issues.append(issue(root,"cycle",id));continue}
            let label=target.identifyingTexts.first ?? id
            refs.append(try register(kind:.worldEntity,id:id,revision:target.recordRevision,sources:Set(target.sources),label:label,depth:depth+1,via:claim.predicate,root:root,visited:visited.union([id]),path:path+[claim]))
        }
        return(refs,issues)
    }
    public func bindDisplayed(_ p:PreparedLinkedAppointmentContext,orderedRecordIDs:[String],activeRequestID:UUID)async throws->LinkedDisplayedContext {
        try await validate(p,requestID:activeRequestID)
        guard orderedRecordIDs.count==p.summaries.count,Set(orderedRecordIDs)==Set(p.summaries.map(\.recordID))else{throw LinkedContextError.wrongSelection}
        let id=UUID();displayID=id;return LinkedDisplayedContext(id:id,orderedRecordIDs:orderedRecordIDs,prepared:p)
    }
    public func select(ordinal:Int,in context:LinkedDisplayedContext,activeRequestID:UUID)async throws->LinkedRecordSelection {
        try await validate(context.prepared,requestID:activeRequestID)
        guard displayID==context.id,ordinal>0,ordinal<=context.orderedRecordIDs.count else{throw LinkedContextError.wrongSelection}
        return LinkedRecordSelection(recordID:context.orderedRecordIDs[ordinal-1],displayID:context.id,prepared:context.prepared)
    }
    public func expand(_ reference:LinkedEvidenceReference,in p:PreparedLinkedAppointmentContext,activeRequestID:UUID,
                       selection:LinkedRecordSelection?=nil,worldFields:[WorldPredicate]=[.name,.address,.locatedAt],changeFields:Set<AppointmentField>?=nil)async throws->LinkedEvidenceExpansion {
        guard !busy else{throw SemanticError.existingAttempt};busy=true;defer{busy=false}
        try await validate(p,requestID:activeRequestID)
        guard let authorized=references[reference.id],authorized.reference==reference else{throw LinkedContextError.staleReference}
        if let selection {try await validate(selection.prepared,requestID:activeRequestID);guard displayID==selection.displayID,selection.recordID==authorized.root else{throw LinkedContextError.wrongSelection}}
        // A repeated request can expand MORE fields, but never reuse a smaller
        // cached body as if it answered them or discard facts already returned.
        var effectiveWorldFields=worldFields,effectiveChangeFields=changeFields
        if reference.kind == .worldEntity {
            guard !worldFields.isEmpty,Set(worldFields).count==worldFields.count else{throw MemoryError.unsupportedQuery}
        }
        if let old=expanded[reference.id] {
            switch old.payload {
            case .world(let item):
                let prior=item.fields.map(\.predicate)
                if Set(worldFields).isSubset(of:Set(prior)){return old}
                effectiveWorldFields=prior+worldFields.filter{!prior.contains($0)}
            case .change:
                guard let selectors=expandedSelectors[reference.id]else{throw LinkedContextError.staleReference}
                if selectors.1==nil{return old}
                if let requested=changeFields,requested.isSubset(of:selectors.1!){return old}
                effectiveChangeFields=changeFields.map{selectors.1!.union($0)}
            default:return old
            }
        }
        guard reads<budget.maximumReads,sources.union(reference.sources).count<=budget.maximumSources else{throw LinkedContextError.budgetExceeded}
        reads+=1
        let payload:LinkedEvidencePayload
        var next:[LinkedEvidenceReference]=[],issues:[LinkedContextIssue]=[]
        switch reference.kind {
        case .appointmentFacts:
            let rows=try await store.recordSearchSnapshot(permit:p.permit,recordIDs:[reference.recordID])
            guard let row=rows.records.first,row.projection.recordRevision==reference.recordRevision,Set(reference.sources)==row.projection.sources else{throw LinkedContextError.staleReference}
            payload = .appointment(row.projection)
        case .retainedChange:
            guard let change=try await store.sourceChangeSnapshot(permit:p.permit).first(where:{$0.recordID==reference.recordID && $0.current.recordRevision==reference.recordRevision && $0.sources==Set(reference.sources)})else{throw LinkedContextError.unavailableEvidence}
            payload = .change(change.explanation(fields:effectiveChangeFields))
        case .worldEntity:
            let head=try await store.linkedWorldHeaders(recordIDs:[reference.recordID],permit:p.permit);headers+=1
            guard let h=head.first,h.recordRevision==reference.recordRevision,h.sources==reference.sources else{throw LinkedContextError.staleReference}
            let item=try await store.linkedWorldEvidence(recordID:reference.recordID,requested:effectiveWorldFields,permit:p.permit)
            payload = .world(item)
            let more=try await nextHops(from:item,depth:reference.depth,root:authorized.root,visited:authorized.visited,path:authorized.path,permit:p.permit);next=more.0;issues=more.1
        }
        try await validate(p,requestID:activeRequestID)
        let result=LinkedEvidenceExpansion(reference:reference,rootRecordID:authorized.root,payload:payload,traversalEvidence:authorized.path,nextHops:next,issues:issues)
        let bytes=try encoded(result)
        guard payloadBytes+bytes<=budget.maximumPayloadBytes else{throw LinkedContextError.budgetExceeded}
        payloadBytes+=bytes;sources.formUnion(reference.sources);expanded[reference.id]=result;expandedSelectors[reference.id]=(effectiveWorldFields,effectiveChangeFields);return result
    }
    public func admit(_ p:PreparedLinkedAppointmentContext,activeRequestID:UUID,requiredReferences:[LinkedEvidenceReference])async throws->LinkedContextSnapshot {
        try await validate(p,requestID:activeRequestID)
        guard requiredReferences.allSatisfy({references[$0.id]?.reference==$0})else{throw LinkedContextError.staleReference}
        return LinkedContextSnapshot(expansions:expanded.values.sorted{$0.reference.id.uuidString<$1.reference.id.uuidString},outstandingReferences:references.values.map(\.reference).filter{expanded[$0.id]==nil},
            metrics:LinkedContextMetrics(evidenceReadAttempts:reads,preparationRecordsRead:preparationReads,headerRecordsRead:headers,distinctExpandedSources:sources.count,expandedPayloadBytes:payloadBytes,summaryBytes:summaryBytes,modelCalls:0),
            allRequestedReferencesExpanded:requiredReferences.allSatisfy{expanded[$0.id] != nil})
    }
}

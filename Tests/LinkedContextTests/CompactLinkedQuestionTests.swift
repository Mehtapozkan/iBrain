import Foundation
import Testing
import IBrain
import IBrainSemantics
import IBrainRetrieval

private let fiveDetails:Set<LinkedUnitDetail>=[.performer,.localDate,.startClock,.venue,.venueAddress]
private func closeCompact(_ f:WholeUnitFixture) async { await f.store.close();try? FileManager.default.removeItem(at:f.directory) }
private func compactReceipt(_ prepared:PreparedCompactProductQuestion,_ payload:[String:Any]) throws -> CompactProductQueryReceipt {
    let json=try JSONSerialization.data(withJSONObject:["decision":payload],options:[.sortedKeys,.withoutEscapingSlashes])
    return .init(provider:"AUTHORED-not-inference",model:"AUTHORED",requestSHA256:try prepared.task.digest(),outputJSON:String(decoding:json,as:UTF8.self),elapsedSeconds:0)
}
private func contextualPayload(_ target:String="unit_0",operation:String="details",details:Set<LinkedUnitDetail>=fiveDetails,changes:String="none",facets:[String]=[]) -> [String:Any] {
    ["kind":"contextual","operation":operation,"target":target,"requestedDetails":details.map(\.rawValue).sorted(),"changeFields":changes,"evidenceFacets":facets]
}
private func compactPrepared(_ f:WholeUnitFixture,_ p:PreparedLinkedUnitQuestion) async throws -> PreparedCompactProductQuestion {
    let state=try JSONSerialization.jsonObject(with:Data(p.task.state.utf8)) as! [String:Any]
    let input=WholeUnitFixture.input(f.context,state["latestQuestion"] as! String)
    return try CompactProductQueryPlanner.prepare(taskID:"one-compact-parent",inventory:ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),contextual:p.task,permit:await f.store.permit(),contract:.linkedUnitContextV2)
}
@Test func actualRemainingDetailsCaseHasOneCompactReceiptAllFiveFieldsAndUnknowns() async throws {
    let f=try await WholeUnitFixture(),session=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    let p=try await session.prepare(WholeUnitFixture.input(f.context,"Show the remaining concert details"),context:f.context,activeAnswerRequestID:f.parentID,requestID:UUID(),bindings:f.bindings)
    let compact=try await compactPrepared(f,p),receipt=try compactReceipt(compact,contextualPayload())
    let decision=try CompactProductQueryPlanner.compile(receipt,for:compact)
    let answer=try await session.complete(compactDecision:decision,for:p,activeRequestID:p.requestID)
    #expect(compact.task.version==CompactProductQueryPlanner.linkedUnitVersion)
    #expect(answer.plan.requestedDetails==fiveDetails && answer.rows.count==1 && answer.rows[0].members.count==3)
    #expect(answer.plan.originalReceipt.compactProductQueryReceipt==receipt && answer.plan.originalReceipt.answers.isEmpty)
    #expect(answer.rows[0].gaps.contains{$0.field=="performer"} && answer.rows[0].gaps.contains{$0.field=="localDate"})
    #expect(!answer.allRequestedValuesEstablished && answer.currentOriginalSelections.isEmpty)
    _=try await session.admit(answer,activeRequestID:p.requestID)
    do { _=try await session.complete(answer.plan.originalReceipt,for:p,activeRequestID:p.requestID);Issue.record("Compact parent rebound as standalone child") } catch {}
    await closeCompact(f)
}
@Test func compactFirstSecondAndAllRetainWholeMembersChangesOriginalsAndEvidence() async throws {
    let f=try await WholeUnitFixture(),session=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    let p=try await session.prepare(WholeUnitFixture.input(f.context,"Give current details, all changes, cancellation and booking evidence and current originals."),context:f.context,activeAnswerRequestID:f.parentID,requestID:UUID(),bindings:f.bindings)
    let compact=try await compactPrepared(f,p)
    for (target,counts) in [("unit_0",[3]),("unit_1",[1]),("allDisplayed",[3,1])] {
        let receipt=try compactReceipt(compact,contextualPayload(target,operation:"detailsAndChangesAndCurrentOriginals",changes:"all",facets:["documentedStatus","currentPersonalBooking"]))
        let answer=try await session.complete(compactDecision:CompactProductQueryPlanner.compile(receipt,for:compact),for:p,activeRequestID:p.requestID)
        #expect(answer.rows.map{$0.members.count}==counts && answer.currentOriginalSelections.map{$0.row.unit.members.count}==counts)
        #expect(answer.plan.requestedSourceEvidence==[.documentedStatus,.currentPersonalBooking])
        #expect(answer.rows.allSatisfy{$0.sourceEvidence.members.count==$0.members.count})
        if target != "unit_0" { #expect(answer.rows.last!.expansions.contains{if case .change(let c)=$0.payload{return c.text.contains("Gull Hall")};return false}) }
    }
    await closeCompact(f)
}
@Test func compactV2LocationAndSelectedChangeFieldsUseExistingExpansion() async throws {
    let f=try await WholeUnitFixture(),session=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    let p=try await session.prepare(WholeUnitFixture.input(f.context,"Where is the second event's venue and what changed about its venue?"),context:f.context,activeAnswerRequestID:f.parentID,requestID:UUID(),bindings:f.bindings)
    let compact=try await compactPrepared(f,p)
    let receipt=try compactReceipt(compact,contextualPayload("unit_1",operation:"detailsAndChanges",details:[.venueLocation,.venueAddress],changes:"venue"))
    let a=try await session.complete(compactDecision:CompactProductQueryPlanner.compile(receipt,for:compact),for:p,activeRequestID:p.requestID)
    #expect(a.plan.requestedChanges==[.venue,.venueAddress] && a.rows[0].gaps.isEmpty)
    #expect(a.rows[0].expansions.contains{if case .world(let w)=$0.payload{return w.fields.contains{$0.predicate == .address && $0.claims.contains{$0.value == .text("27 Pier Road")}}};return false})
    #expect(a.rows[0].members[0].appointment.venueAddress==nil)
    await closeCompact(f)
}
@Test func compactV2RejectsDroppedFieldsDuplicateValuesInvalidTargetsAndSmuggledOperations() async throws {
    let f=try await WholeUnitFixture(),session=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    let p=try await session.prepare(WholeUnitFixture.input(f.context,"Show the remaining concert details"),context:f.context,activeAnswerRequestID:f.parentID,requestID:UUID(),bindings:f.bindings)
    let compact=try await compactPrepared(f,p)
    var bad:[ [String:Any] ]=[]
    var missing=contextualPayload();missing.removeValue(forKey:"requestedDetails");bad.append(missing)
    var duplicate=contextualPayload();duplicate["requestedDetails"]=["venue","venue"];bad.append(duplicate)
    var extra=contextualPayload();extra["inventedAnswer"]="Hall";bad.append(extra)
    bad += [contextualPayload("unit_2"),contextualPayload("unclear"),contextualPayload(operation:"details",details:[]),contextualPayload(operation:"currentOriginals"),contextualPayload(operation:"details",changes:"all"),contextualPayload(operation:"changes",details:[],changes:"none"),contextualPayload(operation:"sourceEvidence",details:[]),contextualPayload(operation:"olderOriginals",details:[])]
    for payload in bad {let receipt=try compactReceipt(compact,payload);#expect(throws:(any Error).self){try CompactProductQueryPlanner.compile(receipt,for:compact)}}
    for route in ["unsupported","unknown","clarify"] {
        let receipt=try compactReceipt(compact,["kind":route,"reason":"operation"])
        let decision=try CompactProductQueryPlanner.compile(receipt,for:compact)
        do { _=try await session.complete(compactDecision:decision,for:p,activeRequestID:p.requestID);Issue.record("No-execution branch executed") } catch {}
    }
    await closeCompact(f)
}
@Test func compactInventoryDateQuestionsRetainStandaloneBranchWithAndWithoutNonemptyParent() async throws {
    let f=try await WholeUnitFixture(),session=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    let input=WholeUnitFixture.input(f.context,"Which concerts are today?")
    let p=try await session.prepare(input,context:f.context,activeAnswerRequestID:f.parentID,requestID:UUID(),bindings:f.bindings)
    let inventory=try ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4)
    var payload:[String:Any]=["kind":"inventory","operation":"list","unit":"occurrences","window":"today","status":"all","documentKind":"eventTicket","clockBounds":[],"predicates":[],"requestedDetails":["performer","localDate","startClock","venue","venueAddress"],"evidenceFacets":[]]
    for contextual in [Optional(p.task),nil] {
        let prepared=try CompactProductQueryPlanner.prepare(taskID:"new-inventory",inventory:inventory,contextual:contextual,permit:await f.store.permit(),contract:.linkedUnitContextV2)
        let receipt=try compactReceipt(prepared,payload),decision=try CompactProductQueryPlanner.compile(receipt,for:prepared)
        let plan=try ExhaustiveAppointmentPlanner.compile(compactDecision:decision,input:input,policy:.resultUnitsV4)
        #expect(decision.route == .inventory && plan.requestedDetails.count==5 && plan.receipt.compactProductQueryReceipt==receipt)
        // Empty answers carry no object parent. Native scheduling clears aliases;
        // compact-v2's nil-context branch is deliberately still a full inventory.
        payload["status"]="cancelled"
    }
    await closeCompact(f)
}
@Test func compactV2CurrentnessForgetAndCancellationFenceDetailsAndOriginals() async throws {
    for forgetting in [false,true] {
        let f=try await WholeUnitFixture(),session=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
        let p=try await session.prepare(WholeUnitFixture.input(f.context,"Give the second event's current details and originals"),context:f.context,activeAnswerRequestID:f.parentID,requestID:UUID(),bindings:f.bindings)
        let compact=try await compactPrepared(f,p),receipt=try compactReceipt(compact,contextualPayload("unit_1",operation:"detailsAndCurrentOriginals"))
        let decision=try CompactProductQueryPlanner.compile(receipt,for:compact)
        let answer=try await session.complete(compactDecision:decision,for:p,activeRequestID:p.requestID)
        try await f.store.invalidateSource(id:"photo-update",forget:forgetting)
        do { _=try await session.admit(answer,activeRequestID:p.requestID);Issue.record("Changed/forgotten compact answer published") } catch {}
        do { _=try await session.complete(compactDecision:decision,for:p,activeRequestID:p.requestID);Issue.record("Changed/forgotten compact plan executed") } catch {}
        await closeCompact(f)
    }
    let f=try await WholeUnitFixture(),session=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    let p=try await session.prepare(WholeUnitFixture.input(f.context,"Show current details"),context:f.context,activeAnswerRequestID:f.parentID,requestID:UUID(),bindings:f.bindings)
    let compact=try await compactPrepared(f,p),decision=try CompactProductQueryPlanner.compile(compactReceipt(compact,contextualPayload()),for:compact)
    let answer=try await session.complete(compactDecision:decision,for:p,activeRequestID:p.requestID)
    await session.cancel()
    do { _=try await session.admit(answer,activeRequestID:p.requestID);Issue.record("Cancelled compact answer published") } catch {}
    await closeCompact(f)
}
@Test func compactV1WireBytesAndReceiptsRemainExactAndCannotReplayAsV2() async throws {
    let parent=UUID(uuidString:"11111111-1111-1111-1111-111111111111")!,display=UUID(uuidString:"22222222-2222-2222-2222-222222222222")!
    let f=try await WholeUnitFixture(parentIdentity:parent,displayIdentity:display)
    let input=WholeUnitFixture.input(f.context,"Open the second event's current originals.")
    let oldChild=try await f.owner.prepareDisplayedUnitFollowup(input,context:f.context,activeAnswerRequestID:parent)
    let inventory=try ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
    for (contextual,name) in [(Optional(oldChild.task),"COMPACT-V1-CONTEXT"),(nil,"COMPACT-V1-INVENTORY")] {
        let p=try CompactProductQueryPlanner.prepare(taskID:"legacy-compact-wire",inventory:inventory,contextual:contextual,permit:await f.store.permit())
        let url=try #require(Bundle.module.url(forResource:name,withExtension:"json",subdirectory:"Fixtures"))
        #expect(try encoder.encode(p.task)==Data(contentsOf:url))
    }
    let old=try CompactProductQueryPlanner.prepare(taskID:"same-id",inventory:inventory,contextual:oldChild.task,permit:await f.store.permit())
    let receipt=try compactReceipt(old,["kind":"contextual","operation":"currentOriginals","target":"unit_1","evidenceFacets":[]])
    let roundtrip=try JSONDecoder().decode(CompactProductQueryReceipt.self,from:encoder.encode(receipt))
    #expect(roundtrip==receipt)
    let session=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    let linked=try await session.prepare(input,context:f.context,activeAnswerRequestID:parent,requestID:UUID(),bindings:f.bindings)
    let permit=try await f.store.permit()
    #expect(throws:(any Error).self){try CompactProductQueryPlanner.prepare(taskID:"reject-default",inventory:inventory,contextual:linked.task,permit:permit)}
    let v2=try await compactPrepared(f,linked)
    #expect(throws:(any Error).self){try CompactProductQueryPlanner.compile(receipt,for:v2)}
    let v2receipt=try compactReceipt(v2,contextualPayload("unit_1",operation:"currentOriginals",details:[]))
    #expect(throws:(any Error).self){try CompactProductQueryPlanner.compile(v2receipt,for:old)}
    await closeCompact(f)
}

@Test func compactV2IndependentHostReconstructionUsesOneActualParentDigest() async throws {
    let parent=UUID(),display=UUID(),request=UUID()
    let phone=try await WholeUnitFixture(parentIdentity:parent,displayIdentity:display)
    let host=try await WholeUnitFixture(parentIdentity:parent,displayIdentity:display)
    let a=try LinkedUnitQuestionSession(store:phone.store,unitOwner:phone.owner)
    let b=try LinkedUnitQuestionSession(store:host.store,unitOwner:host.owner)
    let question="For the second event give current details and all changes and current originals."
    let x=try await a.prepare(WholeUnitFixture.input(phone.context,question),context:phone.context,activeAnswerRequestID:parent,requestID:request,bindings:phone.bindings)
    let y=try await b.prepare(WholeUnitFixture.input(host.context,question),context:host.context,activeAnswerRequestID:parent,requestID:request,bindings:host.bindings)
    let px=try await compactPrepared(phone,x),py=try await compactPrepared(host,y)
    #expect(try px.task.digest()==py.task.digest())
    let receipt=try compactReceipt(px,contextualPayload("unit_1",operation:"detailsAndChangesAndCurrentOriginals",changes:"all"))
    let dx=try CompactProductQueryPlanner.compile(receipt,for:px),dy=try CompactProductQueryPlanner.compile(receipt,for:py)
    let ax=try await a.complete(compactDecision:dx,for:x,activeRequestID:request)
    let ay=try await b.complete(compactDecision:dy,for:y,activeRequestID:request)
    #expect(ax.rows.map(\.members)==ay.rows.map(\.members))
    do { _=try await b.complete(compactDecision:dx,for:y,activeRequestID:request);Issue.record("Foreign store permit accepted") } catch {}
    do { _=try await b.complete(compactDecision:dy,for:x,activeRequestID:request);Issue.record("Foreign prepared authority accepted") } catch {}
    await closeCompact(phone);await closeCompact(host)
}

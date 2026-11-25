import Foundation
import Testing
import IBrain
import IBrainSemantics
import IBrainRetrieval

private let exactQ2="What venue and street address are printed on the first ticket?"
private func memberPrepare(_ f:MemberContractFixture,_ s:LinkedUnitQuestionSession,_ question:String=exactQ2,_ request:UUID=UUID())async throws->PreparedLinkedUnitQuestion {
    try await s.prepare(MemberContractFixture.input(f.context,question),context:f.context,activeAnswerRequestID:f.parentID,requestID:request,policy:.memberDetailsV3)
}
private func memberParent(_ f:MemberContractFixture,_ p:PreparedLinkedUnitQuestion)async throws->PreparedCompactProductQuestion {
    let state=try JSONSerialization.jsonObject(with:Data(p.task.state.utf8)) as! [String:Any]
    let input=MemberContractFixture.input(f.context,state["latestQuestion"] as! String)
    return try CompactProductQueryPlanner.prepare(taskID:"one-member-parent",inventory:ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),contextual:p.task,permit:await f.store.permit(),contract:.memberDetailsV3)
}
private func memberOutput(_ target:String="unit_0_member_0",scope:String="printedOwnSource",operation:String="details",details:[String]=["venue","venueAddress"],changes:String="none",facets:[String]=[])->[String:Any] {
    ["kind":"contextual","operation":operation,"target":target,"requestedDetails":details,"changeFields":changes,"evidenceFacets":facets,"evidenceScope":scope]
}
private func memberReceipt(_ p:PreparedCompactProductQuestion,_ decision:[String:Any])throws->CompactProductQueryReceipt {
    let json=try JSONSerialization.data(withJSONObject:["decision":decision],options:[.sortedKeys,.withoutEscapingSlashes])
    return .init(provider:"AUTHORED-NOT-INFERENCE",model:"AUTHORED",requestSHA256:try p.task.digest(),outputJSON:String(decoding:json,as:UTF8.self),elapsedSeconds:0)
}
private func memberDecision(_ p:PreparedCompactProductQuestion,_ output:[String:Any])throws->CompiledCompactProductQuestion {
    try CompactProductQueryPlanner.compile(memberReceipt(p,output),for:p)
}
private func memberTarget(_ f:MemberContractFixture,_ recordID:String)->String {
    for (i,row) in f.context.orderedRows.enumerated(){for (j,member) in row.unit.members.enumerated()where member.projection.recordID==recordID{return "unit_\(i)_member_\(j)"}}
    preconditionFailure("Fixture member absent")
}
@Test func memberContractExactQ2KeepsFullParentAndMissingFirstTicketInsteadOfSibling()async throws {
    let f=try await MemberContractFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    let p=try await memberPrepare(f,s),parent=try await memberParent(f,p)
    let receipt=try memberReceipt(parent,memberOutput()),decision=try CompactProductQueryPlanner.compile(receipt,for:parent)
    let answer=try await s.complete(compactDecision:decision,for:p,activeRequestID:p.requestID)
    #expect(p.task.state.contains(exactQ2) && parent.task.version==CompactProductQueryPlanner.memberAwareVersion)
    #expect(answer.parentContextID==f.context.id && answer.parentAnswerRequestID==f.parentID)
    #expect(answer.rows.count==1 && answer.rows[0].members.count==2 && answer.rows[0].answerMembers.map(\.recordID)==["z-ticket-first"])
    #expect(answer.plan.selectedMemberPath?.unitOrdinal==1 && answer.plan.selectedMemberPath?.memberOrdinal==1)
    #expect(answer.plan.evidenceScope == .printedOwnSource && answer.rows[0].scopedDetails?.count==2)
    #expect(answer.rows[0].scopedDetails!.allSatisfy{$0.recordID=="z-ticket-first" && $0.value==nil && !$0.established})
    #expect(Set(answer.rows[0].gaps.map(\.field))==["venue","venueAddress"] && !answer.allRequestedValuesEstablished)
    #expect(answer.rows[0].expansions.isEmpty && answer.currentOriginalSelections.isEmpty)
    #expect(answer.plan.originalReceipt.answers.isEmpty && answer.plan.originalReceipt.compactProductQueryReceipt==receipt)
    #expect(answer.rows[0].selection.proof.queryReceipt.requestSHA256==f.context.proof.queryReceipt.requestSHA256)
    if let path=ProcessInfo.processInfo.environment["IBRAIN_MEMBER_ARTIFACT_DIR"] {
        let directory=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes,.prettyPrinted]
        try encoder.encode(parent.task).write(to:directory.appendingPathComponent("COMPACT-PARENT-TASK.json"))
        try encoder.encode(p.task).write(to:directory.appendingPathComponent("NATIVE-CONTEXT-TASK.json"))
        try encoder.encode(receipt).write(to:directory.appendingPathComponent("AUTHORED-PARENT-RECEIPT.json"))
        try encoder.encode(answer.rows[0].scopedDetails).write(to:directory.appendingPathComponent("SCOPED-DETAILS.json"))
        try encoder.encode(answer.plan.selectedMemberPath).write(to:directory.appendingPathComponent("MEMBER-PATH.json"))
        try encoder.encode(answer.rows[0].members).write(to:directory.appendingPathComponent("FULL-PARENT-MEMBERS.json"))
    }
    _=try await s.admit(answer,activeRequestID:p.requestID)
    do{_=try await s.complete(answer.plan.originalReceipt,for:p,activeRequestID:p.requestID);Issue.record("Parent became child receipt")}catch{}
    await f.close()
}
@Test func memberContractSecondTicketFirstConcertAndWholeOriginalNeighbors()async throws {
    let f=try await MemberContractFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    let p=try await memberPrepare(f,s,"Give details of the referenced ticket or concert."),parent=try await memberParent(f,p)
    let second=try await s.complete(compactDecision:memberDecision(parent,memberOutput("unit_0_member_1")),for:p,activeRequestID:p.requestID)
    #expect(second.rows[0].answerMembers.map(\.recordID)==["a-ticket-second"])
    #expect(second.rows[0].scopedDetails?.first{$0.detail == .venue}?.value=="ARENA ARMEEC")
    #expect(second.rows[0].scopedDetails?.first{$0.detail == .venueAddress}?.value=="Asen Yordanov Blvd., Sofia")
    #expect(second.rows[0].gaps.isEmpty && second.allRequestedValuesEstablished)
    for target in ["unit_0","allDisplayed"] {
        let whole=try await s.complete(compactDecision:memberDecision(parent,memberOutput(target,scope:"currentSaved",operation:"detailsAndCurrentOriginals")),for:p,activeRequestID:p.requestID)
        #expect(whole.plan.selectedMemberPath==nil && whole.rows[0].answerMembers.count==2 && whole.currentOriginalSelections[0].row.unit.members.count==2)
        #expect(whole.rows[0].scopedDetails==nil && whole.rows[0].gaps.contains{$0.recordID=="z-ticket-first"})
    }
    await f.close()
}
@Test func memberContractPrintedCorrectionUsesObservedSameSourceBeforeNotOwnerScalar()async throws {
    for history in [true,false] {
        let f=try await MemberContractFixture(corrected:true,retainHistory:history),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
        #expect(!f.context.identityResolved)
        let target=memberTarget(f,"a-ticket-second")
        for scope in ["currentSaved","printedOwnSource"] {
            let question=scope=="currentSaved" ? "What venue is currently saved for this ticket?":"What venue is printed on this ticket?"
            let p=try await memberPrepare(f,s,question),parent=try await memberParent(f,p)
            let answer=try await s.complete(compactDecision:memberDecision(parent,memberOutput(target,scope:scope,details:["venue"])),for:p,activeRequestID:p.requestID)
            let value=try #require(answer.rows[0].scopedDetails?.first)
            if scope=="currentSaved" {#expect(value.value=="Owner Room" && value.support?.origin == .domainCorrection && value.valueRecordRevision==2)}
            else {
                if history {#expect(value.value=="ARENA ARMEEC" && value.support?.origin == .observed && value.valueRecordRevision==1 && value.basis == .retainedObservedBeforeCorrection)}
                else {#expect(value.value==nil && !value.established && value.basis == .notEstablished)}
                #expect(answer.rows[0].expansions.isEmpty)
            }
            #expect(answer.rows[0].answerMembers[0].appointment.venue=="Owner Room")
            #expect(answer.rows[0].selection.row.membershipUncertain)
        }
        await f.close()
    }
}
@Test func memberContractRejectsOutOfRangeMixedScopesAndMemberOperationBroadening()async throws {
    let f=try await MemberContractFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    let p=try await memberPrepare(f,s),parent=try await memberParent(f,p)
    var missing=memberOutput();missing.removeValue(forKey:"evidenceScope")
    let bad=[missing,memberOutput("unit_1_member_0"),memberOutput("unit_0_member_2"),memberOutput("member_0"),memberOutput(scope:"printedAndCurrent"),memberOutput(operation:"detailsAndCurrentOriginals"),memberOutput(operation:"detailsAndChanges",changes:"all"),memberOutput(facets:["currentPersonalBooking"]),memberOutput("unit_0",operation:"detailsAndChanges",changes:"all")]
    for output in bad {let receipt=try memberReceipt(parent,output);#expect(throws:(any Error).self){try CompactProductQueryPlanner.compile(receipt,for:parent)}}
    for route in ["clarify","unsupported"] {
        let decision=try memberDecision(parent,["kind":route,"reason":"target"])
        do{_=try await s.complete(compactDecision:decision,for:p,activeRequestID:p.requestID);Issue.record("No-execution choice executed")}catch{}
    }
    await f.close()
}
@Test func memberContractNewInventoryDateBranchSurvivesNonemptyAndEmptyParent()async throws {
    let f=try await MemberContractFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    let input=MemberContractFixture.input(f.context,"Which concerts are today?"),p=try await memberPrepare(f,s,input.question)
    let inventory=try ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4)
    for context in [Optional(p.task),nil] {
        let parent=try CompactProductQueryPlanner.prepare(taskID:"member-inventory",inventory:inventory,contextual:context,permit:await f.store.permit(),contract:.memberDetailsV3)
        let output:[String:Any]=["kind":"inventory","operation":"list","unit":"occurrences","window":"today","status":"all","documentKind":"eventTicket","clockBounds":[],"predicates":[],"requestedDetails":["venue","venueAddress"],"evidenceFacets":[]]
        let decision=try memberDecision(parent,output),plan=try ExhaustiveAppointmentPlanner.compile(compactDecision:decision,input:input,policy:.resultUnitsV4)
        #expect(decision.route == .inventory && plan.question==input.question && plan.requestedDetails==[.venue,.venueAddress])
    }
    await f.close()
}
@Test func memberContractStaleParentCancellationAndForgetFenceOutput()async throws {
    for mode in ["home","cancel","forget"] {
        let f=try await MemberContractFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
        let p=try await memberPrepare(f,s),parent=try await memberParent(f,p),decision=try memberDecision(parent,memberOutput())
        let answer=try await s.complete(compactDecision:decision,for:p,activeRequestID:p.requestID)
        if mode=="home" {try await f.owner.clearDisplayedUnitContext(f.context.id)}
        if mode=="cancel" {await s.cancel()}
        if mode=="forget" {try await f.store.invalidateSource(id:"AUTHORED-two-ticket-photo",forget:true)}
        do{_=try await s.admit(answer,activeRequestID:p.requestID);Issue.record("Stale member answer admitted")}catch{}
        do{_=try await s.complete(compactDecision:decision,for:p,activeRequestID:p.requestID);Issue.record("Stale member operation executed")}catch{}
        await f.close()
    }
}
@Test func memberContractReplicaTaskEqualityAndWrongParentRejection()async throws {
    let parent=UUID(),display=UUID(),request=UUID()
    let a=try await MemberContractFixture(parentIdentity:parent,displayIdentity:display),b=try await MemberContractFixture(parentIdentity:parent,displayIdentity:display)
    let x=try LinkedUnitQuestionSession(store:a.store,unitOwner:a.owner),y=try LinkedUnitQuestionSession(store:b.store,unitOwner:b.owner)
    let px=try await memberPrepare(a,x,exactQ2,request),py=try await memberPrepare(b,y,exactQ2,request)
    let cx=try await memberParent(a,px),cy=try await memberParent(b,py)
    #expect(try cx.task.digest()==cy.task.digest())
    let receipt=try memberReceipt(cx,memberOutput()),dx=try CompactProductQueryPlanner.compile(receipt,for:cx),dy=try CompactProductQueryPlanner.compile(receipt,for:cy)
    let ax=try await x.complete(compactDecision:dx,for:px,activeRequestID:request),ay=try await y.complete(compactDecision:dy,for:py,activeRequestID:request)
    #expect(ax.rows[0].scopedDetails==ay.rows[0].scopedDetails)
    do{_=try await y.complete(compactDecision:dx,for:py,activeRequestID:request);Issue.record("Foreign parent permit accepted")}catch{}
    do{_=try await y.complete(compactDecision:dy,for:px,activeRequestID:request);Issue.record("Foreign native prepared authority accepted")}catch{}
    let other=try await MemberContractFixture(),z=try LinkedUnitQuestionSession(store:other.store,unitOwner:other.owner)
    let pz=try await memberPrepare(other,z,exactQ2,request),cz=try await memberParent(other,pz)
    #expect(throws:(any Error).self){try CompactProductQueryPlanner.compile(receipt,for:cz)}
    await a.close();await b.close();await other.close()
}
@Test func memberContractDefaultV1AndV2WireBytesRemainExactlyV36()async throws {
    let parent=UUID(uuidString:"11111111-1111-1111-1111-111111111111")!,display=UUID(uuidString:"22222222-2222-2222-2222-222222222222")!,request=UUID(uuidString:"33333333-3333-3333-3333-333333333333")!
    let f=try await WholeUnitFixture(parentIdentity:parent,displayIdentity:display),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    let input=WholeUnitFixture.input(f.context,"For the second event give current details, location, all changes and current originals.")
    let p=try await s.prepare(input,context:f.context,activeAnswerRequestID:parent,requestID:request,bindings:f.bindings)
    let compact=try CompactProductQueryPlanner.prepare(taskID:"compact-linked-parent",inventory:ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),contextual:p.task,permit:await f.store.permit(),contract:.linkedUnitContextV2)
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
    for (name,data) in [("V36-TASK",try encoder.encode(p.task)),("V36-COMPACT-V2-TASK",try encoder.encode(compact.task))] {
        let url=try #require(Bundle.module.url(forResource:name,withExtension:"json",subdirectory:"Fixtures"));#expect(try data==Data(contentsOf:url))
    }
    let legacyInput=WholeUnitFixture.input(f.context,"Open the second event's current originals.")
    let child=try await f.owner.prepareDisplayedUnitFollowup(legacyInput,context:f.context,activeAnswerRequestID:parent),inventory=try ExhaustiveAppointmentPlanner.task(legacyInput,policy:.resultUnitsV4)
    for (context,name) in [(Optional(child.task),"COMPACT-V1-CONTEXT"),(nil,"COMPACT-V1-INVENTORY")] {
        let old=try CompactProductQueryPlanner.prepare(taskID:"legacy-compact-wire",inventory:inventory,contextual:context,permit:await f.store.permit())
        let url=try #require(Bundle.module.url(forResource:name,withExtension:"json",subdirectory:"Fixtures"));#expect(try encoder.encode(old.task)==Data(contentsOf:url))
    }
    let member=try await s.prepare(input,context:f.context,activeAnswerRequestID:parent,requestID:UUID(),bindings:f.bindings,policy:.memberDetailsV3),permit=try await f.store.permit()
    #expect(throws:(any Error).self){try CompactProductQueryPlanner.prepare(taskID:"reject-v2",inventory:ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),contextual:member.task,permit:permit,contract:.linkedUnitContextV2)}
    #expect(throws:(any Error).self){try CompactProductQueryPlanner.prepare(taskID:"reject-v3",inventory:ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),contextual:p.task,permit:permit,contract:.memberDetailsV3)}
    await f.store.close();try? FileManager.default.removeItem(at:f.directory)
}

import Foundation
import Testing
import IBrain
import IBrainSemantics
import IBrainRetrieval

private let postCorrectionQuestion="List the current saved concert-ticket details, including my venue correction."
private func savedReadTask(_ f:MemberContractFixture,_ question:String=postCorrectionQuestion)async throws->PreparedCompactProductQuestion {
    let input=MemberContractFixture.input(nil,question)
    return try CompactProductQueryPlanner.prepare(taskID:"current-saved-read",inventory:ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),contextual:nil,permit:await f.store.permit(),contract:.currentSavedInventoryV21)
}
private func savedReadOutput(_ details:[String]=["performer","localDate","startClock","venue","venueAddress"],window:String="all")->[String:Any] {
    ["kind":"inventory","operation":"list","unit":"documents","window":window,"status":"all","documentKind":"eventTicket","clockBounds":[],"predicates":[],"requestedDetails":details,"evidenceFacets":[]]
}
private func savedReadReceipt(_ prepared:PreparedCompactProductQuestion,_ decision:[String:Any])throws->CompactProductQueryReceipt {
    let json=try JSONSerialization.data(withJSONObject:["decision":decision],options:[.sortedKeys,.withoutEscapingSlashes])
    return .init(provider:"AUTHORED-READ-INTENT-NOT-MODEL",model:"AUTHORED",requestSHA256:try prepared.task.digest(),outputJSON:String(decoding:json,as:UTF8.self),elapsedSeconds:0)
}
@Test func currentSavedReadExactFailedQuestionIncludesCurrentCorrectionWithoutNewFactsOrEdit()async throws {
    let f=try await MemberContractFixture(corrected:true),p=try await savedReadTask(f)
    #expect(p.task.version=="photo-product-query-compact-v2.1-current-saved-inventory")
    #expect(p.task.state.contains(postCorrectionQuestion) && !p.task.state.contains("Owner Room") && !p.task.state.contains("ARENA ARMEEC") && !p.task.state.contains("ticket-second"))
    #expect(!p.task.instructions.contains("MEMBER CONTRACT:") && !p.task.instructions.contains("The opt-in contextual branch"))
    let state=try JSONSerialization.jsonObject(with:Data(p.task.state.utf8)) as! [String:Any],policy=state["readValuePolicy"] as! [String:Any]
    #expect(policy["basis"] as? String=="currentSaved" && policy["includesAlreadyConfirmedCorrections"] as? Bool==true)
    #expect(policy["createsCorrections"] as? Bool==false && policy["comparesHistoricalValues"] as? Bool==false && policy["filtersByCorrectionOrigin"] as? Bool==false && policy["suppliesFactualValuesToModel"] as? Bool==false)
    let receipt=try savedReadReceipt(p,savedReadOutput()),decision=try CompactProductQueryPlanner.compile(receipt,for:p)
    let input=MemberContractFixture.input(nil,postCorrectionQuestion),reader=ExhaustiveAppointmentSession(store:f.store),request=UUID()
    _=try await reader.prepare(input,requestID:request,compactDecision:decision,planningPolicy:.resultUnitsV4)
    let records=try await reader.advance(activeRequestID:request),answer=try await reader.inventoryUnitAnswer(records,prepared:f.preparedDocuments,activeRequestID:request)
    let members=answer.orderedUnits.flatMap(\.members).map(\.projection),first=try #require(members.first{$0.recordID=="z-ticket-first"}),second=try #require(members.first{$0.recordID=="a-ticket-second"})
    #expect(answer.resultUnit == .documents && answer.exactCount==2 && members.count==2 && !answer.requestedAnswerComplete)
    #expect(first.appointment.venue==nil && second.appointment.venue=="Owner Room" && second.recordRevision==2)
    #expect(second.support.first{$0.field == .venue}?.origin == .domainCorrection && second.support.first{$0.field == .venue}?.anchors.first?.quote=="ARENA ARMEEC")
    #expect(answer.queryReceipt.compactProductQueryReceipt==receipt)
    #expect(records.plan.requestedDetails==[.performer,.localDate,.startClock,.venue,.venueAddress])
    let changes=try await f.store.sourceChangeSnapshot(permit:f.store.permit())
    #expect(changes.count==1 && changes[0].previous.appointment.venue=="ARENA ARMEEC" && changes[0].current.appointment.venue=="Owner Room")
    if let path=ProcessInfo.processInfo.environment["IBRAIN_SAVED_READ_ARTIFACT_DIR"] {
        let dir=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        try encoder.encode(p.task).write(to:dir.appendingPathComponent("CURRENT-SAVED-TASK.json"))
        try encoder.encode(receipt).write(to:dir.appendingPathComponent("AUTHORED-READ-RECEIPT.json"))
        try encoder.encode(members).write(to:dir.appendingPathComponent("NATIVE-CURRENT-MEMBERS.json"))
    }
    await f.close()
}
@Test func currentSavedReadDoesNotAddActionsHistoryOrCorrectionOnlyFilterCapabilities()async throws {
    let f=try await MemberContractFixture(corrected:true)
    for question in ["Change the saved venue to another room.","Show the previous and corrected venue values side by side.","List only tickets whose venue I corrected.","List original printed venues rather than my saved venue changes."] {
        let p=try await savedReadTask(f,question)
        #expect(p.task.state.contains(question))
        #expect(p.task.instructions.contains("ONLY corrected records/fields") && p.task.instructions.contains("CREATE/UPDATE") && p.task.instructions.contains("old-to-new comparison") && p.task.instructions.contains("cannot be dropped"))
        let explicit=try savedReadReceipt(p,["kind":"unsupported","reason":"meaning"])
        #expect(try CompactProductQueryPlanner.compile(explicit,for:p).route == .unsupported)
        var mutation=savedReadOutput();mutation["operation"]="update";mutation["newVenue"]="UNTRUSTED-VALUE"
        #expect(throws:(any Error).self){try CompactProductQueryPlanner.compile(savedReadReceipt(p,mutation),for:p)}
        var history=savedReadOutput();history["operation"]="changes"
        #expect(throws:(any Error).self){try CompactProductQueryPlanner.compile(savedReadReceipt(p,history),for:p)}
        var correctedOnly=savedReadOutput();correctedOnly["predicates"]=[["field":"correctionOrigin","operator":"contains","start":"w0","end":"w0"]]
        #expect(throws:(any Error).self){try CompactProductQueryPlanner.compile(savedReadReceipt(p,correctedOnly),for:p)}
    }
    await f.close()
}
@Test func currentSavedReadNoParentFlagCannotReplaceAProvidedParentOrInventScopeFields()async throws {
    let f=try await MemberContractFixture(corrected:true),session=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    let input=MemberContractFixture.input(f.context,postCorrectionQuestion),child=try await session.prepare(input,context:f.context,activeAnswerRequestID:f.parentID,requestID:UUID(),policy:.memberDetailsV3),permit=try await f.store.permit()
    #expect(throws:(any Error).self){try CompactProductQueryPlanner.prepare(taskID:"wrong-native-route",inventory:ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),contextual:child.task,permit:permit,contract:.currentSavedInventoryV21)}
    let p=try await savedReadTask(f)
    var extra=savedReadOutput();extra["evidenceScope"]="currentSaved"
    #expect(throws:(any Error).self){try CompactProductQueryPlanner.compile(savedReadReceipt(p,extra),for:p)}
    let decision=try CompactProductQueryPlanner.compile(savedReadReceipt(p,savedReadOutput()),for:p)
    try await f.store.invalidateSource(id:"AUTHORED-two-ticket-photo",forget:true)
    do{try await decision.validateCurrentAuthority(in:f.store);Issue.record("Read policy bypassed withdrawal")}catch{}
    await f.close()
}
@Test func currentSavedReadExplicitWindowAndNoExecutionStayExact()async throws {
    let f=try await MemberContractFixture(corrected:true)
    let question="List the current saved concert tickets next week, with their current venue, including any confirmed corrections."
    let p=try await savedReadTask(f,question),decision=try CompactProductQueryPlanner.compile(savedReadReceipt(p,savedReadOutput(["venue"],window:"nextWeek")),for:p)
    let plan=try ExhaustiveAppointmentPlanner.compile(compactDecision:decision,input:MemberContractFixture.input(nil,question),policy:.resultUnitsV4)
    #expect(plan.question==question && plan.requestedDetails==[.venue])
    for route in ["clarify","unknown","unsupported"] {
        let good=try savedReadReceipt(p,["kind":route,"reason":"meaning"])
        #expect(try CompactProductQueryPlanner.compile(good,for:p).route.rawValue==route)
        let bad=try savedReadReceipt(p,["kind":route,"reason":"meaning","valueBasis":"currentSaved"])
        #expect(throws:(any Error).self){try CompactProductQueryPlanner.compile(bad,for:p)}
    }
    await f.close()
}
@Test func currentSavedReadParentV31TaskAndBothOldInventoryPreparationsRemainFrozen()async throws {
    let url=try #require(Bundle.module.url(forResource:"V38-PARENT-V31-TASK",withExtension:"json",subdirectory:"Fixtures")),encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
    let frozen=try JSONDecoder().decode(CompactProductQueryTask.self,from:Data(contentsOf:url)),state=try JSONSerialization.jsonObject(with:Data(frozen.state.utf8)) as! [String:Any],branches=(state["preparedState"] as! [String:Any])["branches"] as! [String:Any],context=(branches["contextual"] as! [String:Any])["state"] as! [String:Any]
    let parent=UUID(uuidString:context["parentAnswerRequestID"] as! String)!,display=UUID(uuidString:context["parentContextID"] as! String)!,request=UUID(uuidString:context["requestID"] as! String)!
    let f=try await MemberContractFixture(parentIdentity:parent,displayIdentity:display),session=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    let question=context["latestQuestion"] as! String,input=MemberContractFixture.input(f.context,question)
    let child=try await session.prepare(input,context:f.context,activeAnswerRequestID:parent,requestID:request,policy:.memberDetailsV3)
    let now=try CompactProductQueryPlanner.prepare(taskID:frozen.id,inventory:ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),contextual:child.task,permit:await f.store.permit(),contract:.memberDetailsV3)
    #expect(try encoder.encode(now.task)==encoder.encode(frozen))
    let nilURL=try #require(Bundle.module.url(forResource:"V38-NO-PARENT-V31-TASK",withExtension:"json",subdirectory:"Fixtures")),nilFrozen=try JSONDecoder().decode(CompactProductQueryTask.self,from:Data(contentsOf:nilURL))
    let oldNil=try CompactProductQueryPlanner.prepare(taskID:nilFrozen.id,inventory:ExhaustiveAppointmentPlanner.task(MemberContractFixture.input(nil,question),policy:.resultUnitsV4),contextual:nil,permit:await f.store.permit(),contract:.memberDetailsV3)
    #expect(try encoder.encode(oldNil.task)==encoder.encode(nilFrozen))
    let p=try await savedReadTask(f),receipt=try savedReadReceipt(p,savedReadOutput())
    let oldV2=try CompactProductQueryPlanner.prepare(taskID:p.task.id,inventory:ExhaustiveAppointmentPlanner.task(MemberContractFixture.input(nil,postCorrectionQuestion),policy:.resultUnitsV4),contextual:nil,permit:await f.store.permit(),contract:.linkedUnitContextV2)
    #expect(p.task.responseSchemaJSON==oldV2.task.responseSchemaJSON)
    #expect(throws:(any Error).self){try CompactProductQueryPlanner.compile(receipt,for:oldV2)}
    let oldReceipt=try savedReadReceipt(oldV2,savedReadOutput())
    #expect(throws:(any Error).self){try CompactProductQueryPlanner.compile(oldReceipt,for:p)}
    await f.close()
}

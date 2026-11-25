import Foundation
import Testing
import IBrain
import IBrainSemantics
import IBrainRetrieval

private struct SavedLocationControl {
    let f:DocumentIdentityFixture, context:DisplayedUnitContext, session:LinkedUnitQuestionSession
    let child:PreparedLinkedUnitQuestion, parent:PreparedCompactProductQuestion
    init(mode:String="different", count:Int=1, question:String="Where is the saved appointment?") async throws {
        f=try await DocumentIdentityFixture(mode:mode,sourceCount:count)
        context=try await f.owner.contextForDisplayedInventoryUnitAnswer(f.answer,activeRequestID:f.requestID,displayedUnitIDs:f.answer.orderedUnits.map(\.id))
        session=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
        let input=WholeUnitFixture.input(context,question)
        child=try await session.prepare(input,context:context,activeAnswerRequestID:f.requestID,requestID:UUID(),policy:.locationExtentV4)
        parent=try CompactProductQueryPlanner.preparePhotoCalendarLocationExtent(taskID:"AUTHORED-location-parent",inventory:ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),contextual:child.task,sources:await f.store.sourceSearchSnapshot(permit:f.store.permit()))
    }
    func answer(_ output:[String:Any]) async throws->LinkedUnitQuestionAnswer {
        try await session.complete(compactDecision:locationDecision(parent,output),for:child,activeRequestID:child.requestID)
    }
}
private func locationOutput(extent:String="currentLocation",target:String="unit_0",scope:String="currentSaved",operation:String="details",details:[String]=["venueLocation"],changes:String="none",facets:[String]=[])->[String:Any] {
    ["kind":"contextual","operation":operation,"target":target,"requestedDetails":details,"changeFields":changes,"evidenceFacets":facets,"evidenceScope":scope,"locationExtent":extent]
}
private func locationReceipt(_ p:PreparedCompactProductQuestion,_ decision:[String:Any])throws->CompactProductQueryReceipt {
    .init(provider:"AUTHORED-OFFLINE-CONTROL",model:"NO-INFERENCE",requestSHA256:try p.task.digest(),outputJSON:String(decoding:try JSONSerialization.data(withJSONObject:["decision":decision],options:[.sortedKeys,.withoutEscapingSlashes]),as:UTF8.self),elapsedSeconds:0)
}
private func locationDecision(_ p:PreparedCompactProductQuestion,_ output:[String:Any])throws->CompiledCompactProductQuestion {
    try CompactProductQueryPlanner.compile(locationReceipt(p,output),for:p)
}
private func locationReject(_ body:()async throws->Void)async {
    do { try await body();Issue.record("Invalid/stale location operation accepted") } catch {}
}
@Test func savedLocationExtentOwnAddressIsRenderableAttributedAndOriginalsStayBound()async throws {
    let c=try await SavedLocationControl(question:"Give the venue, location and start time and open its original.")
    let a=try await c.answer(locationOutput(operation:"detailsAndCurrentOriginals",details:["venue","venueAddress","venueLocation","startClock"]))
    #expect(a.plan.locationExtent == .currentLocation && a.plan.evidenceScope == .currentSaved)
    #expect(a.allRequestedValuesEstablished && a.allSelectedMemberReadsComplete && a.rows.count==1)
    #expect(a.rows[0].gaps.isEmpty && a.rows[0].scopedDetails?.count==4)
    let value=try #require(a.rows[0].scopedDetails?.first{$0.detail == .venueLocation})
    #expect(value.value=="AUTHORED 31 Main Street" && value.established && value.basis == .currentProjection)
    #expect(value.support?.origin == .observed && value.support?.anchors.first?.source == c.f.sources[0].reference)
    #expect(value.recordID==c.f.projections[0].recordID && value.currentRecordRevision==1 && value.valueRecordRevision==1)
    #expect(a.currentUnitOriginalSources==c.f.projections[0].sources && a.currentOriginalSelections[0].row.unit.members.count==1)
    #expect(a.parentContextID==c.context.id && a.plan.originalReceipt.compactProductQueryReceipt != nil)
    #expect(a.rows[0].expansions.count==1 && !a.personalCalendarComplete)
    _=try await c.session.admit(a,activeRequestID:c.child.requestID)
    if let dir=ProcessInfo.processInfo.environment["IBRAIN_LOCATION_ARTIFACT"] {
        let u=URL(fileURLWithPath:dir);try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true)
        try calendarCanonical(c.child.task).write(to:u.appendingPathComponent("NATIVE-TASK.json"))
        try calendarCanonical(c.parent.task).write(to:u.appendingPathComponent("COMPACT-TASK.json"))
        try calendarCanonical(a.plan.originalReceipt).write(to:u.appendingPathComponent("AUTHORED-RECEIPT.json"))
        try calendarCanonical(a.rows[0].scopedDetails).write(to:u.appendingPathComponent("SCOPED-DETAILS.json"))
    }
    await c.f.close()
}
@Test func savedLocationExtentExplicitContainmentCannotUseOwnAddress()async throws {
    let c=try await SavedLocationControl(question:"Which containing place is the venue inside?")
    let a=try await c.answer(locationOutput(extent:"linkedContainment"))
    #expect(a.plan.locationExtent == .linkedContainment && a.allSelectedMemberReadsComplete && !a.allRequestedValuesEstablished)
    #expect(a.rows[0].gaps.contains{$0.field=="venueLocation" && $0.reason.contains("No proven")})
    #expect(a.rows[0].scopedDetails==nil && a.currentOriginalSelections.isEmpty)
    await c.f.close()
}
@Test func savedLocationExtentMissingOneOfAllMembersCannotBorrowAnotherAddress()async throws {
    let c=try await SavedLocationControl(mode:"missingAddress",count:2,question:"Where are all of those saved appointments?")
    let a=try await c.answer(locationOutput(target:"allDisplayed"))
    #expect(a.rows.count==2 && a.rows.flatMap(\.members).count==2 && !a.allRequestedValuesEstablished)
    let present=try #require(a.rows.first{$0.members[0].recordID=="AUTHORED-record-0"})
    let absent=try #require(a.rows.first{$0.members[0].recordID=="AUTHORED-record-1"})
    #expect(present.gaps.isEmpty && present.scopedDetails?.first?.established==true)
    #expect(absent.scopedDetails==nil && absent.gaps.contains{$0.field=="venueLocation"})
    #expect(absent.members[0].appointment.venueAddress==nil && a.currentOriginalSelections.isEmpty)
    await c.f.close()
}
@Test func savedLocationExtentRequiresTypedFieldOnlyOnNewContextBranch()async throws {
    let c=try await SavedLocationControl()
    var missing=locationOutput();missing.removeValue(forKey:"locationExtent")
    var wrongType=locationOutput();wrongType["locationExtent"]=true
    for output in [missing,wrongType,locationOutput(extent:"unknown"),locationOutput(extent:"notRequested"),locationOutput(details:["venue"]),locationOutput(extent:"linkedContainment",target:"unit_0_member_0"),locationOutput(extent:"linkedContainment",scope:"printedOwnSource")] {
        #expect(throws:(any Error).self){try locationDecision(c.parent,output)}
    }
    for kind in ["clarify","unknown","unsupported"] {
        #expect(try locationDecision(c.parent,["kind":kind,"reason":"meaning"]).route.rawValue==kind)
        #expect(throws:(any Error).self){try locationDecision(c.parent,["kind":kind,"reason":"meaning","locationExtent":"notRequested"])}
    }
    let inventory:[String:Any]=["kind":"inventory","operation":"list","unit":"documents","window":"all","status":"all","documentKind":"all","clockBounds":[],"predicates":[],"requestedDetails":["venueAddress"],"evidenceFacets":[]]
    #expect(try locationDecision(c.parent,inventory).route == .inventory)
    var extra=inventory;extra["locationExtent"]="notRequested"
    #expect(throws:(any Error).self){try locationDecision(c.parent,extra)}
    let native=try JSONSerialization.jsonObject(with:Data(c.child.task.state.utf8)) as! [String:Any]
    #expect(native["latestQuestion"] as? String == "Where is the saved appointment?")
    #expect(c.parent.task.version==CompactProductQueryPlanner.locationExtentVersion && c.child.task.version==LinkedUnitQuestionSession.locationExtentVersion)
    await c.f.close()
}
@Test func savedLocationExtentCannotBeEnabledByOldBuilderOrReceiptRebound()async throws {
    let c=try await SavedLocationControl(),input=WholeUnitFixture.input(c.context,"Where is the saved appointment?")
    let inventory=try ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),sources=try await c.f.store.sourceSearchSnapshot(permit:c.f.store.permit())
    #expect(throws:(any Error).self){try CompactProductQueryPlanner.preparePhotoCalendarDefaults(taskID:"old",inventory:inventory,contextual:c.child.task,sources:sources)}
    #expect(throws:(any Error).self){try CompactProductQueryPlanner.prepare(taskID:"old",inventory:inventory,contextual:c.child.task,permit:sources.permit,contract:.memberDetailsV3)}
    let old=try await c.session.prepare(input,context:c.context,activeAnswerRequestID:c.f.requestID,requestID:UUID(),policy:.memberDetailsV3)
    #expect(throws:(any Error).self){try CompactProductQueryPlanner.preparePhotoCalendarLocationExtent(taskID:"new",inventory:inventory,contextual:old.task,sources:sources)}
    let receipt=try locationReceipt(c.parent,locationOutput())
    let alien=try CompactProductQueryPlanner.preparePhotoCalendarLocationExtent(taskID:"other-id",inventory:inventory,contextual:nil,sources:sources)
    #expect(throws:(any Error).self){try CompactProductQueryPlanner.compile(receipt,for:alien)}
    await locationReject{_=try await c.session.complete(compactDecision:locationDecision(c.parent,locationOutput()),for:old,activeRequestID:old.requestID)}
    await c.f.close()
}
@Test func savedLocationExtentKeepsMemberPrintedScopeMissingSiblingAndCorrectionProvenance()async throws {
    for corrected in [false,true] {
        let f=try await MemberContractFixture(corrected:corrected,retainHistory:true),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
        for recordID in ["z-ticket-first","a-ticket-second"] {
            let (i,j)=f.context.orderedRows.enumerated().compactMap { i,row -> (Int,Int)? in
                guard let j=row.unit.members.firstIndex(where:{$0.projection.recordID==recordID}) else{return nil};return (i,j)
            }.first!
            let target="unit_\(i)_member_\(j)"
            let input=MemberContractFixture.input(f.context,"What venue and location are printed on this ticket?")
            let p=try await s.prepare(input,context:f.context,activeAnswerRequestID:f.parentID,requestID:UUID(),policy:.locationExtentV4)
            let parent=try CompactProductQueryPlanner.preparePhotoCalendarLocationExtent(taskID:"AUTHORED-member-location",inventory:ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),contextual:p.task,sources:await f.store.sourceSearchSnapshot(permit:f.store.permit()))
            let a=try await s.complete(compactDecision:locationDecision(parent,locationOutput(target:target,scope:"printedOwnSource",details:["venue","venueLocation"])),for:p,activeRequestID:p.requestID)
            #expect(a.rows[0].answerMembers.count==1 && a.rows[0].members.count==f.context.orderedRows[i].unit.members.count && a.rows[0].expansions.isEmpty)
            let values=try #require(a.rows[0].scopedDetails)
            if recordID=="z-ticket-first" {#expect(values.allSatisfy{!$0.established && $0.value==nil})}
            else {
                #expect(values.first{$0.detail == .venue}?.value=="ARENA ARMEEC")
                #expect(values.first{$0.detail == .venueLocation}?.value=="Asen Yordanov Blvd., Sofia")
                #expect(values.allSatisfy{$0.support?.origin == .observed})
                if corrected {#expect(values.first{$0.detail == .venue}?.basis == .retainedObservedBeforeCorrection)}
            }
        }
        await f.close()
    }
}
@Test func savedLocationExtentLinkedContainmentRequiresReadContainingNodeAndRetainsBudgets()async throws {
    for limited in [false,true] {
        let f=try await WholeUnitFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner,budget:limited ? .init(maximumReads:2):.init())
        let input=WholeUnitFixture.input(f.context,"For the second event, give its containing place and address.")
        let p=try await s.prepare(input,context:f.context,activeAnswerRequestID:f.parentID,requestID:UUID(),bindings:f.bindings,policy:.locationExtentV4)
        let parent=try CompactProductQueryPlanner.preparePhotoCalendarLocationExtent(taskID:"AUTHORED-linked-location",inventory:ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),contextual:p.task,sources:await f.store.sourceSearchSnapshot(permit:f.store.permit()))
        let a=try await s.complete(compactDecision:locationDecision(parent,locationOutput(extent:"linkedContainment",target:"unit_1",details:["venueLocation","venueAddress"])),for:p,activeRequestID:p.requestID)
        if limited {#expect(!a.allRequestedValuesEstablished && !a.allSelectedMemberReadsComplete && a.rows[0].gaps.contains{$0.field=="expansion"})}
        else {#expect(a.allRequestedValuesEstablished && a.allSelectedMemberReadsComplete && a.rows[0].expansions.contains{$0.reference.depth==2})}
        #expect(a.rows[0].scopedDetails==nil && a.rows[0].members==[f.f.current])
        await f.store.close();try? FileManager.default.removeItem(at:f.directory)
    }
}
@Test func savedLocationExtentLifecycleRejectsLatePublicationAndOriginalHandoff()async throws {
    for mode in ["cancel","home","forget","withdraw","revision","replace"] {
        let c=try await SavedLocationControl(),decision=try locationDecision(c.parent,locationOutput(operation:"detailsAndCurrentOriginals"))
        let a=try await c.session.complete(compactDecision:decision,for:c.child,activeRequestID:c.child.requestID)
        if mode=="cancel" {await c.session.cancel()}
        if mode=="home" {try await c.f.owner.clearDisplayedUnitContext(c.context.id)}
        if mode=="forget" || mode=="withdraw" {try await c.f.store.invalidateSource(id:c.f.sources[0].reference.id,forget:mode=="forget")}
        if mode=="revision" {
            let source=SourceSnapshot(reference:.init(id:c.f.sources[0].reference.id,revision:2,fingerprint:"AUTHORED-new-revision"),scope:c.f.sources[0].scope,observations:[])
            try await c.f.store.synchronize(.init(sources:[source],records:[]))
        }
        if mode=="replace" {_=try await c.session.prepare(WholeUnitFixture.input(c.context,"Show its address."),context:c.context,activeAnswerRequestID:c.f.requestID,requestID:UUID(),policy:.locationExtentV4)}
        await locationReject{_=try await c.session.admit(a,activeRequestID:c.child.requestID)}
        await locationReject{_=try await c.session.complete(compactDecision:decision,for:c.child,activeRequestID:c.child.requestID)}
        await c.f.close()
    }
}
@Test func savedLocationExtentCurrentLocationKeepsEveryWholeUnitMemberAndUsesLinkedFallback()async throws {
    let f=try await WholeUnitFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    for target in ["unit_0","unit_1"] {
        let input=WholeUnitFixture.input(f.context,"Where is the referenced event?")
        let p=try await s.prepare(input,context:f.context,activeAnswerRequestID:f.parentID,requestID:UUID(),bindings:f.bindings,policy:.locationExtentV4)
        let parent=try CompactProductQueryPlanner.preparePhotoCalendarLocationExtent(taskID:"AUTHORED-multi-member-location",inventory:ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),contextual:p.task,sources:await f.store.sourceSearchSnapshot(permit:f.store.permit()))
        let a=try await s.complete(compactDecision:locationDecision(parent,locationOutput(target:target)),for:p,activeRequestID:p.requestID)
        #expect(a.allRequestedValuesEstablished && a.allSelectedMemberReadsComplete)
        if target=="unit_0" {
            #expect(a.rows[0].members.count==3 && a.rows[0].scopedDetails?.count==3)
            #expect(Set(a.rows[0].scopedDetails!.map(\.recordID))==Set(a.rows[0].members.map(\.recordID)))
            #expect(a.rows[0].scopedDetails!.allSatisfy{$0.value=="1 Main St" && $0.established})
        } else {
            #expect(a.rows[0].scopedDetails==nil && a.rows[0].members==[f.f.current])
            #expect(a.rows[0].expansions.contains{$0.reference.depth==2})
        }
    }
    await f.store.close();try? FileManager.default.removeItem(at:f.directory)
}
@Test func savedLocationExtentCurrentSavedCorrectionKeepsOriginAndAllRequestedFields()async throws {
    let f=try await MemberContractFixture(corrected:true,retainHistory:true),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    let index=f.context.orderedRows.firstIndex{$0.unit.members.contains{$0.projection.recordID=="a-ticket-second"}}!
    let input=MemberContractFixture.input(f.context,"Give the saved venue and where it is.")
    let p=try await s.prepare(input,context:f.context,activeAnswerRequestID:f.parentID,requestID:UUID(),policy:.locationExtentV4)
    let parent=try CompactProductQueryPlanner.preparePhotoCalendarLocationExtent(taskID:"AUTHORED-corrected-location",inventory:ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),contextual:p.task,sources:await f.store.sourceSearchSnapshot(permit:f.store.permit()))
    let a=try await s.complete(compactDecision:locationDecision(parent,locationOutput(target:"unit_\(index)",details:["venue","venueLocation"])),for:p,activeRequestID:p.requestID)
    let values=try #require(a.rows[0].scopedDetails)
    #expect(values.count==2 && values.first{$0.detail == .venue}?.value=="Owner Room")
    #expect(values.first{$0.detail == .venue}?.support?.origin == .domainCorrection)
    #expect(values.first{$0.detail == .venueLocation}?.support?.origin == .observed)
    #expect(a.rows[0].selection.row.membershipUncertain && !a.allRequestedValuesEstablished)
    await f.close()
}
@Test func savedLocationExtentRawAndUnifiedReceiptsPreserveSameTypedMeaningAndConfidence()async throws {
    let c=try await SavedLocationControl()
    var values=["operation":"details","target":"unit_0","changeFields":"none","evidenceScope":"currentSaved","locationExtent":"currentLocation"]
    for d in LinkedUnitDetail.allCases {values["detail_"+d.rawValue]=d == .venueLocation ? "required":"optional"}
    for f in RequestedSourceEvidence.allCases {values["evidence_"+f.rawValue]="optional"}
    let raw=DecisionReceipt(provider:"AUTHORED-OFFLINE-CONTROL",model:"NO-INFERENCE",requestSHA256:try c.child.task.digest(),answers:values.mapValues{.init(choice:$0)},elapsedSeconds:0)
    let a=try await c.session.complete(raw,for:c.child,activeRequestID:c.child.requestID)
    #expect(a.allRequestedValuesEstablished && a.plan.locationExtent == .currentLocation)
    let input=WholeUnitFixture.input(c.context,"Where is the saved appointment?")
    let product=try ProductQuestionPlanner.prepare(taskID:"AUTHORED-unified-location",inventory:ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),contextual:c.child.task,permit:await c.f.store.permit())
    let unified=DecisionReceipt(provider:"AUTHORED-OFFLINE-CONTROL",model:"NO-INFERENCE",requestSHA256:try product.task.digest(),answers:product.task.questions.mapValues{_ in ChoiceAnswer(choice:"notApplicable")}.merging(Dictionary(uniqueKeysWithValues:values.map{("contextual__"+$0.key,ChoiceAnswer(choice:$0.value))})){_,n in n}.merging(["route":ChoiceAnswer(choice:"contextual")]){_,n in n},elapsedSeconds:0)
    let b=try await c.session.complete(productDecision:ProductQuestionPlanner.compile(unified,for:product),for:c.child,activeRequestID:c.child.requestID)
    #expect(b.allRequestedValuesEstablished && b.rows[0].scopedDetails==a.rows[0].scopedDetails)
    var low=raw.answers;low["locationExtent"]=ChoiceAnswer(choice:"currentLocation",confidence:0.5,probabilities:["currentLocation":0.5,"linkedContainment":0.3,"notRequested":0.2])
    let lowReceipt=DecisionReceipt(provider:"jev",model:"jev-1.13.0",requestSHA256:try c.child.task.digest(),answers:low,elapsedSeconds:0)
    await locationReject{_=try await c.session.complete(lowReceipt,for:c.child,activeRequestID:c.child.requestID)}
    await c.f.close()
}
@Test func savedLocationExtentColdReopenCannotRestoreDisplayedAnswerAuthority()async throws {
    let c=try await SavedLocationControl(),a=try await c.answer(locationOutput(operation:"detailsAndCurrentOriginals"))
    await c.f.store.close()
    let reopened=try MemoryStore(directory:c.f.directory,scope:c.f.sources[0].scope)
    try await reopened.synchronize(.init(sources:c.f.sources,records:c.f.projections.map{.init(id:$0.recordID,revision:$0.recordRevision,sources:$0.sources)}))
    let rows=try await reopened.recordSearchSnapshot(permit:reopened.permit(),recordIDs:Set(c.f.projections.map(\.recordID)))
    #expect(rows.records.count==1 && rows.records[0].projection==c.f.projections[0])
    let owner=ExhaustiveAppointmentSession(store:reopened),s=try LinkedUnitQuestionSession(store:reopened,unitOwner:owner)
    await locationReject{_=try await s.admit(a,activeRequestID:c.child.requestID)}
    await reopened.close();try? FileManager.default.removeItem(at:c.f.directory)
}

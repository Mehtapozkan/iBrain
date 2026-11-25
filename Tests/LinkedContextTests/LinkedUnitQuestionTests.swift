import Foundation
import Testing
import IBrain
import IBrainSemantics
import IBrainRetrieval

private func rejects(_ action:() async throws->Void)async {do{try await action();Issue.record("Invalid/stale contextual operation accepted")}catch{}}
private func close(_ f:WholeUnitFixture)async {await f.store.close();try? FileManager.default.removeItem(at:f.directory)}
private func prepare(_ s:LinkedUnitQuestionSession,_ f:WholeUnitFixture,_ id:UUID=UUID())async throws->PreparedLinkedUnitQuestion {
    try await s.prepare(WholeUnitFixture.input(f.context,"For the second event, give its current date/start and venue location/address, explain all changes and open its current originals."),context:f.context,activeAnswerRequestID:f.parentID,requestID:id,bindings:f.bindings)
}
@Test func actualUnitSecondDetailsChangesAndOriginalsRetainNativeProof()async throws {
    let f=try await WholeUnitFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner),p=try await prepare(s,f)
    let receipt=try authoredLinkedReceipt(p.task),a=try await s.complete(receipt,for:p,activeRequestID:p.requestID)
    #expect(f.context.orderedRows.map{$0.unit.members.count}==[3,1])
    #expect(a.rows.count==1 && a.rows[0].members==[f.f.current] && a.parentContextID==f.context.id)
    #expect(a.currentUnitOriginalSources==f.f.current.sources && a.currentOriginalSelections[0].row.unit.members.count==1)
    #expect(a.rows[0].selection.proof.queryReceipt.requestSHA256==f.context.proof.queryReceipt.requestSHA256)
    #expect(a.plan.originalReceipt.requestSHA256==receipt.requestSHA256 && a.plan.operation == .detailsAndChangesAndCurrentOriginals)
    #expect(a.rows[0].expansions.contains{if case .change(let c)=$0.payload{return c.text.contains("Gull Hall") && c.text.contains("18:30") && c.text.contains("19:30")};return false})
    #expect(a.rows[0].expansions.contains{if case .world(let w)=$0.payload{return w.fields.contains{$0.predicate == .address && $0.claims.contains{$0.value == .text("27 Pier Road")}}};return false})
    #expect(a.rows[0].gaps.isEmpty && a.allSelectedMemberReadsComplete && a.allRequestedValuesEstablished && !a.personalCalendarComplete)
    #expect(a.rows[0].members[0].appointment.venueAddress==nil)
    _=try await s.admit(a,activeRequestID:p.requestID);await close(f)
}
@Test func allDisplayedKeepsEveryMemberAndMissingHistoryInsteadOfRepresentative()async throws {
    let f=try await WholeUnitFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner),p=try await prepare(s,f)
    let receipt=try authoredLinkedReceipt(p.task,target:"allDisplayed",details:[.yearEvidence,.explicitTimeZone])
    let a=try await s.complete(receipt,for:p,activeRequestID:p.requestID)
    #expect(a.rows.map{$0.members.count}==[3,1] && a.currentOriginalSelections.count==2 && a.currentUnitOriginalSources.count==2)
    #expect(Set(a.rows.flatMap(\.members).map(\.recordID))==["ticket1","ticket2","ticket3","appt-A"])
    #expect(a.rows[0].gaps.filter{$0.field=="changes"}.count==3 && a.rows[0].gaps.filter{$0.field=="yearEvidence"}.count==3)
    #expect(a.rows.allSatisfy{$0.sourceEvidence.members.count==$0.members.count})
    #expect(a.allSelectedMemberReadsComplete && !a.allRequestedValuesEstablished && !a.coverage.personalCalendarComplete)
    await close(f)
}
@Test func originalAndEvidenceCompoundKeepsWholeUnitAndCancellationUncertainty()async throws {
    let f=try await WholeUnitFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner),p=try await prepare(s,f)
    let r=try authoredLinkedReceipt(p.task,operation:"currentOriginals",target:"unit_0",details:[],changes:"none",facets:[.documentedStatus,.currentPersonalBooking])
    let a=try await s.complete(r,for:p,activeRequestID:p.requestID)
    #expect(a.currentOriginalSelections.count==1 && a.currentOriginalSelections[0].row.unit.members.count==3)
    #expect(a.rows[0].sourceEvidence.members.allSatisfy{!$0.provesNotCancelled && !$0.provesNoCancellationNoticePrinted})
    #expect(a.rows[0].selection.currentPersonalBooking == .notEstablishedByPhotoEvidence)
    #expect(a.plan.requestedSourceEvidence==[.documentedStatus,.currentPersonalBooking]);await close(f)
}
@Test func noExecutionReceiptsCannotSmuggleDetailsTargetsOrOriginals()async throws {
    let f=try await WholeUnitFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner),p=try await prepare(s,f)
    for op in ["clarify","unsupported"] {
        let good=try authoredLinkedReceipt(p.task,operation:op,target:"unclear",details:[],changes:"none")
        let a=try await s.complete(good,for:p,activeRequestID:p.requestID)
        #expect(a.rows.isEmpty && a.currentOriginalSelections.isEmpty && !a.allRequestedValuesEstablished)
        let bad=try authoredLinkedReceipt(p.task,operation:op,target:"unit_0",details:[.venue],changes:"none")
        await rejects{_=try await s.complete(bad,for:p,activeRequestID:p.requestID)}
    }
    await close(f)
}
@Test func actualReceiptDigestConfidenceAndForeignSessionRemainRequired()async throws {
    let f=try await WholeUnitFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner),p=try await prepare(s,f)
    let other=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    await rejects{_=try await other.complete(authoredLinkedReceipt(p.task),for:p,activeRequestID:p.requestID)}
    let forged=DecisionReceipt(provider:"AUTHORED",model:"AUTHORED",requestSHA256:String(repeating:"0",count:64),answers:try authoredLinkedReceipt(p.task).answers,elapsedSeconds:0)
    await rejects{_=try await s.complete(forged,for:p,activeRequestID:p.requestID)}
    let raw=try authoredLinkedReceipt(p.task)
    let answers: [String:ChoiceAnswer]=Dictionary(uniqueKeysWithValues:p.task.questions.map{key,q in
        let chosen=raw.answers[key]!.choice
        let probabilities: [String:Double]=Dictionary(uniqueKeysWithValues:q.criteria.keys.map{($0,$0==chosen ? 0.7:0.3/Double(q.criteria.count-1))})
        return(key,ChoiceAnswer(choice:chosen,confidence:0.7,probabilities:probabilities))
    })
    let low=DecisionReceipt(provider:"jev",model:"jev-1.13.0",requestSHA256:try p.task.digest(),answers:answers,elapsedSeconds:0)
    await rejects{_=try await s.complete(low,for:p,activeRequestID:p.requestID)}
    let second=try await prepare(s,f)
    await rejects{_=try await s.complete(raw,for:second,activeRequestID:second.requestID)}
    await close(f)
}
@Test func homeContextReplacementAndCancelFenceLatePublication()async throws {
    let f=try await WholeUnitFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner),p=try await prepare(s,f)
    let a=try await s.complete(authoredLinkedReceipt(p.task),for:p,activeRequestID:p.requestID)
    await s.cancel();await rejects{_=try await s.admit(a,activeRequestID:p.requestID)}
    let next=try await prepare(s,f)
    try await f.owner.clearDisplayedUnitContext(f.context.id)
    await rejects{_=try await s.complete(authoredLinkedReceipt(next.task),for:next,activeRequestID:next.requestID)}
    await close(f)
}
@Test func withdrawnMemberAndForgetInvalidateWholeAnswerIncludingOriginals()async throws {
    let f=try await WholeUnitFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner),p=try await prepare(s,f)
    let a=try await s.complete(authoredLinkedReceipt(p.task,target:"allDisplayed"),for:p,activeRequestID:p.requestID)
    try await f.store.invalidateSource(id:"three-ticket-photo",forget:true)
    await rejects{_=try await s.admit(a,activeRequestID:p.requestID)}
    await rejects{_=try await s.complete(authoredLinkedReceipt(p.task),for:p,activeRequestID:p.requestID)}
    await close(f)
}
@Test func sourceRevisionCannotReuseOldPlanOrEvidence()async throws {
    let f=try await WholeUnitFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner),p=try await prepare(s,f)
    let before=f.f.sources.first{$0.reference.id=="photo-update"}!,ref=SourceReference(id:before.reference.id,revision:2,fingerprint:"AUTHORED-changed-pixels")
    let changed=SourceSnapshot(reference:ref,scope:before.scope,observations:before.observations)
    let snapshot=try await f.store.recordSearchSnapshot(permit:f.store.permit()),world=try await f.store.worldSearchSnapshot(permit:f.store.permit()),sources=try await f.store.sourceSearchSnapshot(permit:f.store.permit())
    let recordPins: [DomainRecordPin]=snapshot.records.map(\.projection).map{p in DomainRecordPin(id:p.recordID,revision:p.recordRevision,sources:Set(p.sources.map{$0==before.reference ? ref:$0}))}
    let worldPins: [DomainRecordPin]=world.entities.map(\.projection).map{p in DomainRecordPin(id:p.recordID,revision:p.recordRevision,sources:Set(p.sources.map{$0==before.reference ? ref:$0}),recordKind:.worldEntity)}
    let pins = recordPins + worldPins
    try await f.store.synchronize(AuthoritySnapshot(sources:sources.sources.map{$0.reference==before.reference ? changed:$0},records:pins))
    await rejects{_=try await s.complete(authoredLinkedReceipt(p.task),for:p,activeRequestID:p.requestID)};await close(f)
}
@Test func expansionLimitPreservesCurrentMembersButExplicitlyReturnsPartial()async throws {
    let f=try await WholeUnitFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner,budget:.init(maximumReads:1)),p=try await prepare(s,f)
    let a=try await s.complete(authoredLinkedReceipt(p.task),for:p,activeRequestID:p.requestID)
    #expect(a.rows[0].members==[f.f.current] && a.currentUnitOriginalSources==f.f.current.sources)
    #expect(a.rows[0].expansions.count==1 && !a.allSelectedMemberReadsComplete && !a.allRequestedValuesEstablished)
    #expect(a.rows[0].gaps.contains{$0.field=="expansion"});await close(f)
}
@Test func nativeAuthorityRejectsInferredAddressAndUnknownYearRemainsMissing()async throws {
    do { let invalid=try await WholeUnitFixture(inferredAddress:true); await close(invalid); Issue.record("Native authority accepted an inferred address") }
    catch { #expect(error as? MemoryError == .invalidEvidence) }
    let f=try await WholeUnitFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner),p=try await prepare(s,f)
    let a=try await s.complete(authoredLinkedReceipt(p.task,operation:"details",target:"unit_0",details:[.venueAddress,.yearEvidence],changes:"none"),for:p,activeRequestID:p.requestID)
    #expect(a.rows[0].members.count==3 && !a.allRequestedValuesEstablished)
    #expect(a.rows[0].gaps.filter{$0.field=="venueAddress"}.isEmpty && a.rows[0].gaps.filter{$0.field=="yearEvidence"}.count==3)
    #expect(a.currentOriginalSelections.isEmpty);await close(f)
}
@Test func coldReopenRetainsMemoryAndHistoryButCannotRestoreOpaqueContext()async throws {
    let f=try await WholeUnitFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner),p=try await prepare(s,f)
    let answer=try await s.complete(authoredLinkedReceipt(p.task),for:p,activeRequestID:p.requestID)
    let sources=try await f.store.sourceSearchSnapshot(permit:f.store.permit())
    let records=try await f.store.recordSearchSnapshot(permit:f.store.permit()),world=try await f.store.worldSearchSnapshot(permit:f.store.permit())
    let pins=records.records.map(\.projection).map{DomainRecordPin(id:$0.recordID,revision:$0.recordRevision,sources:$0.sources)}+world.entities.map(\.projection).map{DomainRecordPin(id:$0.recordID,revision:$0.recordRevision,sources:$0.sources,recordKind:.worldEntity)}
    await f.store.close()
    let reopened=try MemoryStore(directory:f.directory,scope:f.f.scope)
    try await reopened.synchronize(AuthoritySnapshot(sources:sources.sources,records:pins))
    let restored=try await reopened.recordSearchSnapshot(permit:reopened.permit()),changes=try await reopened.sourceChangeSnapshot(permit:reopened.permit())
    #expect(restored.records.count==4 && changes.first{$0.recordID=="appt-A"}?.current==f.f.current)
    let newOwner=ExhaustiveAppointmentSession(store:reopened),newSession=try LinkedUnitQuestionSession(store:reopened,unitOwner:newOwner)
    await rejects{_=try await newSession.prepare(WholeUnitFixture.input(f.context,"Show the second event's details."),context:f.context,activeAnswerRequestID:f.parentID,requestID:UUID(),bindings:f.bindings)}
    await rejects{_=try await newSession.admit(answer,activeRequestID:p.requestID)}
    await reopened.close();try? FileManager.default.removeItem(at:f.directory)
}
@Test func unitOwnerAndExpansionMustUseSameNativeStoreInstance()async throws {
    let f=try await WholeUnitFixture()
    let records=try await f.store.recordSearchSnapshot(permit:f.store.permit()),world=try await f.store.worldSearchSnapshot(permit:f.store.permit()),sources=try await f.store.sourceSearchSnapshot(permit:f.store.permit())
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent("split-owner-"+UUID().uuidString)
    let mirror=try MemoryStore(directory:dir,scope:f.f.scope)
    let pins=records.records.map(\.projection).map{DomainRecordPin(id:$0.recordID,revision:$0.recordRevision,sources:$0.sources)}+world.entities.map(\.projection).map{DomainRecordPin(id:$0.recordID,revision:$0.recordRevision,sources:$0.sources,recordKind:.worldEntity)}
    try await mirror.synchronize(AuthoritySnapshot(sources:sources.sources,records:pins))
    _=try await mirror.upsertBatch(records.records.map(\.projection),permit:mirror.permit())
    _=try await mirror.applyWorldBatch(world.entities.map{WorldMemoryWrite($0.projection)},permit:mirror.permit())
    let split=try LinkedUnitQuestionSession(store:mirror,unitOwner:f.owner)
    await rejects{_=try await split.prepare(WholeUnitFixture.input(f.context,"Give the second event's details."),context:f.context,activeAnswerRequestID:f.parentID,requestID:UUID(),bindings:f.bindings)}
    _=try await f.owner.admitDisplayedUnitContext(f.context,activeAnswerRequestID:f.parentID)
    await mirror.close();try? FileManager.default.removeItem(at:dir);await close(f)
}

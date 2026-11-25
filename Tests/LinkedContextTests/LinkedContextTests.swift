import Foundation
import Testing
import IBrain
import IBrainSemantics
import IBrainRetrieval

private func directory()->URL{FileManager.default.temporaryDirectory.appendingPathComponent("dsc1-"+UUID().uuidString)}
private func reference(_ p:PreparedLinkedAppointmentContext,_ kind:LinkedEvidenceKind)->LinkedEvidenceReference {p.summaries[0].nextHops.first{$0.kind==kind}!}

@Test func equalVenueNamesOnDifferentSourcesDoNotProveLinkedIdentity()async throws {
    let f=try Fixture(wrongBuilding:true,sameNameDistractor:true),dir=directory(),store=try await f.install(directory:dir);defer{try? FileManager.default.removeItem(at:dir)}
    let s=try LinkedAppointmentContextSession(store:store),id=UUID(),p=try await s.prepare(bindings:f.bindings,requestID:id)
    let venue=try await s.expand(reference(p,.worldEntity),in:p,activeRequestID:id)
    #expect(venue.nextHops.isEmpty && venue.issues.contains{$0.reason=="targetIdentityNotQuoted"})
    await store.close()
}

@Test func baselineOneHopAndCandidateTwoHopUseSameAdmittedEvidence()async throws {
    let f=try Fixture(),dir=directory(),store=try await f.install(directory:dir);defer{try? FileManager.default.removeItem(at:dir)}
    let id=UUID(),query=WorldMemoryQuery(kind:.event,constraints:[.init(predicate:.name,value:.text("Harbor Quartet"))],requested:[.name,.locatedAt])
    let baseline=try await store.resolveWorldAnswer(store.queryWorldCurrent(query,requestID:id),activeRequestID:id)
    #expect(baseline.relatedEntities.map(\.recordID)==["world-studio"])
    #expect(baseline.relatedEntities.flatMap(\.fields).filter{$0.predicate == .address}.allSatisfy{$0.state == .missing})
    let session=try LinkedAppointmentContextSession(store:store),p=try await session.prepare(bindings:f.bindings,requestID:id)
    let facts=try await session.expand(p.summaries[0].reference,in:p,activeRequestID:id)
    let change=try await session.expand(reference(p,.retainedChange),in:p,activeRequestID:id)
    let venue=try await session.expand(reference(p,.worldEntity),in:p,activeRequestID:id)
    let buildingRef=try #require(venue.nextHops.first),building=try await session.expand(buildingRef,in:p,activeRequestID:id)
    guard case .appointment(let current)=facts.payload,case .change(let changed)=change.payload,case .world(let target)=building.payload else{Issue.record("wrong payload kind");return}
    #expect(current==f.current && current.appointment.venueAddress==nil)
    #expect(changed.fields.contains{$0.field == .date} && changed.fields.contains{$0.field == .venue})
    #expect(target.fields.first{$0.predicate == .address}?.claims.first?.value == .text("27 Pier Road"))
    #expect(building.traversalEvidence.count==2 && building.traversalEvidence.allSatisfy{!$0.anchors.isEmpty})
    #expect(!target.sources.contains{$0.id=="photo-distractor"})
    let result=try await session.admit(p,activeRequestID:id,requiredReferences:[facts.reference,change.reference,venue.reference,building.reference])
    #expect(result.allRequestedReferencesExpanded && result.metrics.evidenceReadAttempts==4 && result.metrics.modelCalls==0)
    #expect(result.outstandingReferences.contains{$0.recordID=="appt-B"})
    await store.close()
}

@Test func actualDisplayedOrderBindsFollowupAndCannotBorrowWrongEvent()async throws {
    let f=try Fixture(),dir=directory(),store=try await f.install(directory:dir);defer{try? FileManager.default.removeItem(at:dir)}
    let s=try LinkedAppointmentContextSession(store:store),id=UUID(),p=try await s.prepare(bindings:f.bindings,requestID:id)
    let displayed=try await s.bindDisplayed(p,orderedRecordIDs:["appt-B","appt-A"],activeRequestID:id)
    let a=try await s.select(ordinal:2,in:displayed,activeRequestID:id),b=try await s.select(ordinal:1,in:displayed,activeRequestID:id)
    _=try await s.expand(reference(p,.retainedChange),in:p,activeRequestID:id,selection:a)
    do{_=try await s.expand(reference(p,.retainedChange),in:p,activeRequestID:id,selection:b);Issue.record("borrowed first-event history")}catch{}
    #expect(p.summaries[1].date.year==nil && !p.summaries[1].hasRetainedChange)
    do{_=try await s.bindDisplayed(p,orderedRecordIDs:["appt-A","appt-A"],activeRequestID:id);Issue.record("duplicate displayed object")}catch{}
    let replacement=try await s.bindDisplayed(p,orderedRecordIDs:["appt-A","appt-B"],activeRequestID:id)
    do{_=try await s.select(ordinal:1,in:displayed,activeRequestID:id);Issue.record("stale displayed context")}catch{}
    _=try await s.select(ordinal:1,in:replacement,activeRequestID:id)
    await store.close()
}

@Test func wrongEventBindingAndUnquotedTargetCannotCreateJoin()async throws {
    let f=try Fixture(wrongBuilding:true),dir=directory(),store=try await f.install(directory:dir);defer{try? FileManager.default.removeItem(at:dir)}
    let s=try LinkedAppointmentContextSession(store:store),id=UUID()
    do{_=try await s.prepare(bindings:[.init(recordID:"appt-B",worldEventID:"world-event-A")],requestID:id);Issue.record("wrong event identity accepted")}catch{}
    let p=try await s.prepare(bindings:f.bindings,requestID:id)
    let venue=try await s.expand(reference(p,.worldEntity),in:p,activeRequestID:id)
    #expect(venue.nextHops.isEmpty && venue.issues.contains{$0.reason=="targetIdentityNotQuoted" && $0.targetID=="world-distractor"})
    #expect(!venue.traversalEvidence.contains{$0.anchors.contains{$0.source.id=="photo-distractor"}})
    await store.close()
}

@Test func cycleDepthAndReadBudgetsStayExplicit()async throws {
    let f=try Fixture(cycle:true),dir=directory(),store=try await f.install(directory:dir);defer{try? FileManager.default.removeItem(at:dir)}
    let id=UUID(),s=try LinkedAppointmentContextSession(store:store,budget:.init(maximumDepth:4)),p=try await s.prepare(bindings:f.bindings,requestID:id)
    let venue=try await s.expand(reference(p,.worldEntity),in:p,activeRequestID:id),building=try await s.expand(venue.nextHops[0],in:p,activeRequestID:id)
    #expect(building.nextHops.isEmpty && building.issues.contains{$0.reason=="cycle"})
    let limited=try LinkedAppointmentContextSession(store:store,budget:.init(maximumDepth:1,maximumReads:1)),lp=try await limited.prepare(bindings:f.bindings,requestID:id)
    let v=try await limited.expand(reference(lp,.worldEntity),in:lp,activeRequestID:id)
    #expect(v.nextHops.isEmpty && v.issues.contains{$0.reason=="depthLimit"})
    do{_=try await limited.expand(lp.summaries[0].reference,in:lp,activeRequestID:id);Issue.record("read budget bypass")}catch{}
    let snap=try await limited.admit(lp,activeRequestID:id,requiredReferences:[lp.summaries[0].reference])
    #expect(!snap.allRequestedReferencesExpanded && snap.metrics.evidenceReadAttempts==1)
    await store.close()
}

@Test func sourceRevisionWithdrawalAndLateResultInvalidateReferences()async throws {
    let f=try Fixture(),dir=directory(),store=try await f.install(directory:dir);defer{try? FileManager.default.removeItem(at:dir)}
    let s=try LinkedAppointmentContextSession(store:store),id=UUID(),p=try await s.prepare(bindings:f.bindings,requestID:id)
    let venue=try await s.expand(reference(p,.worldEntity),in:p,activeRequestID:id)
    try await store.invalidateSource(id:"photo-address",forget:true)
    do{_=try await s.expand(venue.nextHops[0],in:p,activeRequestID:id);Issue.record("revoked address expanded")}catch{}
    do{_=try await s.admit(p,activeRequestID:id,requiredReferences:[]);Issue.record("stale late result admitted")}catch{}
    // Access changes intentionally invalidate the native authority catalog.
    // Pin must reconcile it; the retrieval adapter must not mint its own grant.
    let allowed=Set(f.sources.filter{$0.reference.id != "photo-address"}.map(\.reference))
    try await store.synchronize(AuthoritySnapshot(sources:f.sources.filter{allowed.contains($0.reference)},records:f.authority.records.filter{$0.sources.isSubset(of:allowed)}))
    let fresh=try await s.prepare(bindings:f.bindings,requestID:UUID())
    let v=try await s.expand(reference(fresh,.worldEntity),in:fresh,activeRequestID:fresh.requestID)
    #expect(v.nextHops.isEmpty && !v.issues.isEmpty)
    await s.cancel()
    do{_=try await s.admit(fresh,activeRequestID:fresh.requestID,requiredReferences:[]);Issue.record("cancelled result admitted")}catch{}
    await store.close()
}

@Test func forgedReferenceRejectsAndAdditionalFieldsRetainEarlierFacts()async throws {
    let f=try Fixture(),dir=directory(),store=try await f.install(directory:dir);defer{try? FileManager.default.removeItem(at:dir)}
    let s=try LinkedAppointmentContextSession(store:store),id=UUID(),p=try await s.prepare(bindings:f.bindings,requestID:id),ref=reference(p,.worldEntity)
    var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(ref)) as! [String:Any];object["recordID"]="world-distractor"
    let forged=try JSONDecoder().decode(LinkedEvidenceReference.self,from:JSONSerialization.data(withJSONObject:object))
    do{_=try await s.expand(forged,in:p,activeRequestID:id);Issue.record("decoded metadata grants authority")}catch{}
    let old=try await s.expand(ref,in:p,activeRequestID:id)
    let cached=try await s.expand(ref,in:p,activeRequestID:id)
    #expect(old.reference==cached.reference)
    let extra=try await s.expand(ref,in:p,activeRequestID:id,worldFields:[.description])
    guard case .world(let item)=extra.payload else{Issue.record("wrong expanded body");return}
    #expect(item.fields.map(\.predicate)==[.name,.address,.locatedAt,.description])
    #expect(extra.nextHops==old.nextHops)
    do{_=try await s.expand(ref,in:p,activeRequestID:id,worldFields:[]);Issue.record("invalid selector bypassed through cache")}catch{}
    _=try await s.expand(reference(p,.retainedChange),in:p,activeRequestID:id,changeFields:[.date,.venue,.venueAddress])
    _=try await s.expand(reference(p,.retainedChange),in:p,activeRequestID:id,changeFields:[.date,.venue,.venueAddress])
    let metrics=try await s.admit(p,activeRequestID:id,requiredReferences:[]).metrics
    #expect(metrics.evidenceReadAttempts==3)
    await store.close()
}

@Test func coldReopenRestoresFactsAndHistoryButNotEphemeralReferences()async throws {
    let f=try Fixture(),dir=directory(),store=try await f.install(directory:dir);defer{try? FileManager.default.removeItem(at:dir)}
    let id=UUID(),s=try LinkedAppointmentContextSession(store:store),p=try await s.prepare(bindings:f.bindings,requestID:id)
    _=try await s.expand(reference(p,.retainedChange),in:p,activeRequestID:id)
    await store.close()
    let reopened=try MemoryStore(directory:dir,scope:f.scope);try await reopened.synchronize(f.authority)
    let next=try LinkedAppointmentContextSession(store:reopened),np=try await next.prepare(bindings:f.bindings,requestID:UUID())
    #expect(np.summaries[0].hasRetainedChange && np.summaries[1].date.year==nil)
    do{_=try await next.expand(p.summaries[0].reference,in:p,activeRequestID:id);Issue.record("old reference survived reopen")}catch{}
    let history=try await next.expand(reference(np,.retainedChange),in:np,activeRequestID:np.requestID)
    guard case .change(let change)=history.payload else{Issue.record("history lost");return}
    #expect(change.fields.contains{$0.field == .venue && $0.previousValue=="Gull Hall" && $0.currentValue=="Studio Room"})
    try await reopened.withdraw(recordID:"appt-A",permit:reopened.permit())
    do{_=try await next.prepare(bindings:f.bindings,requestID:UUID());Issue.record("forgotten record recalled")}catch{}
    await reopened.close()
}

@Test func explicitNativeCorrectionReplacesAddressWithoutPromotingItToObservedText()async throws {
    let f=try Fixture(),dir=directory(),store=try await f.install(directory:dir);defer{try? FileManager.default.removeItem(at:dir)}
    let id=UUID(),s=try LinkedAppointmentContextSession(store:store),p=try await s.prepare(bindings:f.bindings,requestID:id)
    let venue=try await s.expand(reference(p,.worldEntity),in:p,activeRequestID:id),oldBuildingRef=venue.nextHops[0]
    let oldRow=try await store.worldSearchSnapshot(permit:store.permit()).entities.first{$0.projection.recordID=="world-building"}!
    let old=oldRow.projection
    let replacement=WorldMemoryProjection(recordID:old.recordID,recordRevision:2,scope:old.scope,kind:old.kind,claims:old.claims.map{c in
        c.predicate == .address ? WorldClaim(id:c.id,predicate:c.predicate,value:.text("29 Pier Road"),origin:.domainCorrection,anchors:c.anchors,extractorVersion:"AUTHORED_NATIVE_OWNER_CORRECTION"):c
    })
    let world=f.world.map{$0.recordID==replacement.recordID ? replacement:$0}
    let authority=AuthoritySnapshot(sources:f.sources,records:f.authority.records.map{r in r.id==replacement.recordID ? DomainRecordPin(id:r.id,revision:2,sources:replacement.sources,recordKind:.worldEntity):r})
    try await store.synchronize(authority)
    _=try await store.applyWorldBatch([WorldMemoryWrite(replacement,expectedMemoryRevision:oldRow.revision)],permit:store.permit())
    do{_=try await s.expand(oldBuildingRef,in:p,activeRequestID:id);Issue.record("old reference survived native correction")}catch{}
    let np=try await s.prepare(bindings:f.bindings,requestID:UUID()),v=try await s.expand(reference(np,.worldEntity),in:np,activeRequestID:np.requestID)
    let building=try await s.expand(v.nextHops[0],in:np,activeRequestID:np.requestID)
    guard case .world(let item)=building.payload else{Issue.record("lost building");return}
    let address=try #require(item.fields.first{$0.predicate == .address}?.claims.first)
    #expect(address.value == .text("29 Pier Road") && address.origin == .domainCorrection && address.anchors.first?.quote=="27 Pier Road")
    #expect(world.count==f.world.count)
    await store.close()
}

@Test func sourceRevisionNeverReusesOldAddressEvidenceAndByteBudgetHolds()async throws {
    let f=try Fixture(),dir=directory(),store=try await f.install(directory:dir);defer{try? FileManager.default.removeItem(at:dir)}
    let s=try LinkedAppointmentContextSession(store:store),id=UUID(),p=try await s.prepare(bindings:f.bindings,requestID:id)
    let oldSource=f.sources.first{$0.reference.id=="photo-address"}!,ref=SourceReference(id:oldSource.reference.id,revision:2,fingerprint:"AUTHORED-new-address")
    let source=SourceSnapshot(reference:ref,scope:f.scope,observations:[.init(id:"name",value:"Maritime Centre"),.init(id:"address",value:"31 Pier Road")])
    let oldRow=try await store.worldSearchSnapshot(permit:store.permit()).entities.first{$0.projection.recordID=="world-building"}!
    let old=oldRow.projection
    let replacement=WorldMemoryProjection(recordID:old.recordID,recordRevision:2,scope:old.scope,kind:old.kind,claims:old.claims.map{c in
        let value:WorldValue=c.predicate == .address ? .text("31 Pier Road"):c.value
        return WorldClaim(id:c.id,predicate:c.predicate,value:value,origin:c.origin,anchors:c.anchors.map{a in a.source==oldSource.reference ? EvidenceAnchor(source:ref,observationID:a.observationID,quote:c.predicate == .address ? "31 Pier Road":a.quote):a},extractorVersion:c.extractorVersion)
    })
    try await store.synchronize(AuthoritySnapshot(sources:f.sources.map{$0.reference.id==ref.id ? source:$0},records:f.authority.records.map{r in r.id==old.recordID ? .init(id:r.id,revision:2,sources:replacement.sources,recordKind:.worldEntity):r}))
    _=try await store.applyWorldBatch([WorldMemoryWrite(replacement,expectedMemoryRevision:oldRow.revision)],permit:store.permit())
    do{_=try await s.admit(p,activeRequestID:id,requiredReferences:[]);Issue.record("old revision admitted")}catch{}
    let np=try await s.prepare(bindings:f.bindings,requestID:UUID()),v=try await s.expand(reference(np,.worldEntity),in:np,activeRequestID:np.requestID),b=try await s.expand(v.nextHops[0],in:np,activeRequestID:np.requestID)
    guard case .world(let item)=b.payload else{Issue.record("no building");return}
    #expect(item.fields.first{$0.predicate == .address}?.claims.first?.value == .text("31 Pier Road"))
    #expect(b.reference.sources.contains(ref) && !b.reference.sources.contains(oldSource.reference))
    let limited=try LinkedAppointmentContextSession(store:store,budget:.init(maximumPayloadBytes:256)),lp=try await limited.prepare(bindings:f.bindings,requestID:UUID())
    do{_=try await limited.expand(lp.summaries[0].reference,in:lp,activeRequestID:lp.requestID);Issue.record("payload byte budget bypass")}catch{}
    let snapshot=try await limited.admit(lp,activeRequestID:lp.requestID,requiredReferences:[lp.summaries[0].reference])
    #expect(!snapshot.allRequestedReferencesExpanded && snapshot.metrics.expandedPayloadBytes==0 && snapshot.metrics.evidenceReadAttempts==1)
    await store.close()
}

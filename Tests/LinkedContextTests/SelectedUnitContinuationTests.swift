import Foundation
import Testing
import IBrain
import IBrainSemantics
import IBrainRetrieval

private struct ContinuationControl {
    let f: DocumentIdentityFixture
    let context: DisplayedUnitContext
    let session: LinkedUnitQuestionSession
    init(mode: String = "different", parentRequest: UUID = UUID(), display: UUID = UUID()) async throws {
        f = try await DocumentIdentityFixture(mode: mode, requestID: parentRequest)
        let relation = try #require(try InventoryDocumentIdentityInterpreter.task(id: "AUTHORED-focus-identity", prepared: f.prepared))
        let receipt = DecisionReceipt(provider: "AUTHORED-OFFLINE", model: "NO-INFERENCE", requestSHA256: try relation.digest(),
            answers: relation.questions.mapValues { _ in .init(choice: "differentDocuments") }, elapsedSeconds: 0)
        let answer = try await f.owner.inventoryUnitAnswer(f.raw, prepared: f.prepared, relationTask: relation,
            relationReceipt: receipt, documentIdentityPolicy: .crossSourceV1, activeRequestID: f.requestID)
        context = try await f.owner.contextForDisplayedInventoryUnitAnswer(answer, activeRequestID: f.requestID,
            displayedUnitIDs: answer.orderedUnits.map(\.id), displayIdentity: display)
        session = try LinkedUnitQuestionSession(store: f.store, unitOwner: f.owner)
    }
    func prepare(_ question: String = "Where is the second event?", focus: LinkedUnitContinuationContext? = nil,
                 request: UUID = UUID(), policy: LinkedUnitQuestionPolicy = .selectedUnitContinuationV5) async throws -> (PreparedLinkedUnitQuestion, PreparedCompactProductQuestion) {
        let input = WholeUnitFixture.input(context, question)
        let child = try await session.prepare(input, context: context, activeAnswerRequestID: f.requestID,
            requestID: request, policy: policy, continuation: focus)
        let parent = try CompactProductQueryPlanner.preparePhotoCalendarSelectedUnitContinuation(taskID: "AUTHORED-continuation",
            inventory: ExhaustiveAppointmentPlanner.task(input, policy: .resultUnitsV4), contextual: child.task,
            sources: await f.store.sourceSearchSnapshot(permit: f.store.permit()))
        return (child, parent)
    }
    func answer(_ question: String = "Where is the second event?", focus: LinkedUnitContinuationContext? = nil,
                request: UUID = UUID(), operation: String = "details", target: String = "unit_1",
                details: [String] = ["venueLocation"], extent: String = "currentLocation") async throws -> (LinkedUnitQuestionAnswer, PreparedCompactProductQuestion) {
        let (child, parent) = try await prepare(question, focus: focus, request: request)
        let answer = try await session.complete(compactDecision: continuationDecision(parent, operation: operation,
            target: target, details: details, extent: extent), for: child, activeRequestID: child.requestID)
        return (answer, parent)
    }
    func publish(_ a: LinkedUnitQuestionAnswer, id: UUID = UUID()) async throws -> LinkedUnitContinuationContext {
        try await session.contextForDisplayedContinuation(a, activeRequestID: a.requestID, publicationID: id)
    }
}
private func continuationReceipt(_ parent: PreparedCompactProductQuestion, output: [String: Any]) throws -> CompactProductQueryReceipt {
    .init(provider: "AUTHORED-OFFLINE-CONTROL", model: "NO-INFERENCE", requestSHA256: try parent.task.digest(),
        outputJSON: String(decoding: try JSONSerialization.data(withJSONObject: ["decision": output], options: [.sortedKeys,.withoutEscapingSlashes]), as: UTF8.self), elapsedSeconds: 0)
}
private func continuationDecision(_ p: PreparedCompactProductQuestion, operation: String = "details", target: String = "unit_1",
                                  details: [String] = ["venueLocation"], extent: String = "currentLocation") throws -> CompiledCompactProductQuestion {
    try CompactProductQueryPlanner.compile(continuationReceipt(p, output: ["kind":"contextual", "operation":operation,
        "target":target, "requestedDetails":details, "locationExtent":extent, "evidenceScope":"currentSaved",
        "changeFields":"none", "evidenceFacets":[]]), for:p)
}
private func continuationReject(_ action: () async throws -> Void) async {
    do { try await action(); Issue.record("Invalid/stale continuation accepted") } catch {}
}
private func continuationState(_ task: ChoiceTask) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(task.state.utf8)) as! [String: Any]
}

@Test func selectedContinuationCarriesAdmittedQ2FocusWithoutRenumberingQ1() async throws {
    let c = try await ContinuationControl()
    let (q2, _) = try await c.answer()
    #expect(q2.allRequestedValuesEstablished && q2.allSelectedMemberReadsComplete)
    let focus = try await c.publish(q2)
    #expect(focus.publication.selectedOrdinal == 2 && focus.publication.parentBindingSHA256 == c.context.bindingSHA256)
    #expect(focus.publication.contextualReceipt.compactProductQueryReceipt != nil)
    let (p, parent) = try await c.prepare("Show its photo.", focus: focus)
    let state = try continuationState(p.task), wire = try #require(state["selectedUnitContinuation"] as? [String: Any])
    #expect(wire["targetAlias"] as? String == "unit_1" && wire["question"] as? String == "Where is the second event?")
    #expect((state["orderedDisplayedUnits"] as? [[String: Any]])?.count == 2)
    #expect(p.task.version == ProductQuestionPlanner.selectedUnitContinuationContract && parent.task.version == CompactProductQueryPlanner.selectedUnitContinuationVersion)
    let a = try await c.session.complete(compactDecision: continuationDecision(parent, operation: "currentOriginals", details: [], extent: "notRequested"), for: p, activeRequestID: p.requestID)
    #expect(a.currentOriginalSelections.count == 1 && a.currentOriginalSelections[0].ordinal == 2)
    #expect(a.currentUnitOriginalSources == c.context.orderedRows[1].currentSources)
    #expect(c.context.orderedRows.count == 2 && a.parentContextID == c.context.id)
    _ = try await c.session.admitDisplayedContinuation(focus)
    await c.f.close()
}
@Test func selectedContinuationExplicitFirstTargetKeepsOriginalFirstAndNewPublicationReplacesFocus() async throws {
    let c = try await ContinuationControl()
    let (a, _) = try await c.answer(); let old = try await c.publish(a)
    let (first, _) = try await c.answer("Where is the first one?", focus: old, target: "unit_0")
    #expect(first.rows[0].selection.ordinal == 1)
    let newer = try await c.publish(first)
    #expect(newer.publication.selectedOrdinal == 1 && newer.publication.depth == 2)
    #expect(newer.publication.previousContinuationBindingSHA256 == old.publication.bindingSHA256)
    await continuationReject { _ = try await c.session.admitDisplayedContinuation(old) }
    _ = try await c.session.admitDisplayedContinuation(newer)
    await continuationReject { try await c.session.clearDisplayedContinuation(old.publication.publicationID) }
    _ = try await c.session.admitDisplayedContinuation(newer)
    await c.f.close()
}
@Test func selectedContinuationNoFocusUnlessPublishedAndNoPartialMultiMemberOrNoExecutionMint() async throws {
    for mode in ["different", "missingAddress", "multi", "member", "clarify"] {
        let c = try await ContinuationControl(mode: mode == "missingAddress" ? mode : "different")
        let (p, parent) = try await c.prepare()
        #expect(try continuationState(p.task)["selectedUnitContinuation"] == nil)
        let decision: CompiledCompactProductQuestion
        if mode == "clarify" {
            let choices = p.task.questions.map { key, _ -> (String, ChoiceAnswer) in
                let value = key == "operation" ? "clarify" : key == "target" ? "unclear" : key == "evidenceScope" ? "currentSaved" : key == "locationExtent" ? "notRequested" : key == "changeFields" ? "none" : "optional"
                return (key,.init(choice:value))
            }
            let a = try await c.session.complete(DecisionReceipt(provider:"AUTHORED-OFFLINE",model:"NO-INFERENCE",requestSHA256:try p.task.digest(),answers:Dictionary(uniqueKeysWithValues:choices),elapsedSeconds:0),for:p,activeRequestID:p.requestID)
            await continuationReject { _ = try await c.publish(a) }
            await c.f.close(); continue
        } else {
            decision = try continuationDecision(parent, target: mode == "multi" ? "allDisplayed" : mode == "member" ? "unit_1_member_0" : "unit_1")
        }
        let a = try await c.session.complete(compactDecision: decision, for: p, activeRequestID: p.requestID)
        if mode != "different" { await continuationReject { _ = try await c.publish(a) } }
        else {
            // Prepared/received alone does not install a focus.
            let (next, _) = try await c.prepare("Show its photo.")
            #expect(try continuationState(next.task)["selectedUnitContinuation"] == nil)
            await continuationReject { _ = try await c.publish(a) }
        }
        await c.f.close()
    }
}
@Test func selectedContinuationCancellationHomeForgetAndRevisionFenceCapabilityAndLateAnswer() async throws {
    for mode in ["cancel", "clearFocus", "home", "forget", "revision", "newInventory"] {
        let c = try await ContinuationControl()
        let (q2, _) = try await c.answer(); let focus = try await c.publish(q2)
        let (q3, parent) = try await c.prepare("Show its photo.", focus: focus)
        let decision = try continuationDecision(parent, operation: "currentOriginals", details: [], extent: "notRequested")
        if mode == "cancel" { await c.session.cancel() }
        if mode == "clearFocus" { try await c.session.clearDisplayedContinuation(focus.publication.publicationID) }
        if mode == "home" { try await c.f.owner.clearDisplayedUnitContext(c.context.id) }
        if mode == "newInventory" { _ = try await c.f.owner.contextForDisplayedInventoryUnitAnswer(c.f.answer,activeRequestID:c.f.requestID,displayedUnitIDs:c.f.answer.orderedUnits.map(\.id)) }
        if mode == "forget" { try await c.f.store.invalidateSource(id: c.f.sources[1].reference.id, forget: true) }
        if mode == "revision" {
            let source = SourceSnapshot(reference: .init(id: c.f.sources[1].reference.id, revision: 2, fingerprint: "changed"), scope: c.f.sources[1].scope, observations: [])
            try await c.f.store.synchronize(.init(sources: [c.f.sources[0],source], records: []))
        }
        await continuationReject { _ = try await c.session.admitDisplayedContinuation(focus) }
        await continuationReject { _ = try await c.session.complete(compactDecision: decision, for: q3, activeRequestID: q3.requestID) }
        await c.f.close()
    }
}
@Test func selectedContinuationReplicaRequiresGenuineParentAndChildReconstruction() async throws {
    let parentID = UUID(), display = UUID(), request = UUID(), publication = UUID()
    let first = try await ContinuationControl(parentRequest: parentID, display: display)
    let (a, p) = try await first.answer(request: request); let focus = try await first.publish(a, id: publication)
    let replica = try await ContinuationControl(parentRequest: parentID, display: display)
    await continuationReject { _ = try await replica.prepare("Show its photo.", focus: focus) }
    let (child, other) = try await replica.prepare(request: request)
    #expect(try p.task.digest() == other.task.digest())
    let retained = try #require(a.plan.originalReceipt.compactProductQueryReceipt)
    let b = try await replica.session.complete(compactDecision:CompactProductQueryPlanner.compile(retained,for:other),for:child,activeRequestID:child.requestID)
    let rebuilt = try await replica.publish(b, id: publication)
    #expect(focus.publication.bindingSHA256 == rebuilt.publication.bindingSHA256)
    let bytes = try JSONEncoder().encode(focus.publication)
    let metadata = try JSONDecoder().decode(LinkedUnitContinuationPublication.self, from: bytes)
    #expect(metadata.bindingSHA256 == rebuilt.publication.bindingSHA256)
    _ = try await replica.session.admitDisplayedContinuation(rebuilt, expectedPublication: metadata)
    var forged = try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
    forged["selectedOrdinal"] = 1
    let forgedPublication = try JSONDecoder().decode(LinkedUnitContinuationPublication.self,from:JSONSerialization.data(withJSONObject:forged))
    await continuationReject { _ = try await replica.session.admitDisplayedContinuation(rebuilt,expectedPublication:forgedPublication) }
    // Decoding metadata did not admit a foreign capability or change native order.
    #expect(replica.context.orderedRows.map { $0.unit.id } == first.context.orderedRows.map { $0.unit.id })
    await continuationReject { _ = try await replica.publish(b, id: publication) }
    await first.f.close(); await replica.f.close()
}
@Test func selectedContinuationOptInRejectsMixedVersionsAndMissingTypedExtent() async throws {
    let c = try await ContinuationControl()
    let (p, parent) = try await c.prepare()
    let input = WholeUnitFixture.input(c.context,"Where is the second event?")
    let inventory = try ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4)
    let sources = try await c.f.store.sourceSearchSnapshot(permit:c.f.store.permit())
    #expect(throws:(any Error).self) { try CompactProductQueryPlanner.preparePhotoCalendarLocationExtent(taskID:"old",inventory:inventory,contextual:p.task,sources:sources) }
    var missing:[String:Any] = ["kind":"contextual","operation":"details","target":"unit_1","requestedDetails":["venueLocation"],"changeFields":"none","evidenceFacets":[],"evidenceScope":"currentSaved"]
    #expect(throws:(any Error).self) { try CompactProductQueryPlanner.compile(continuationReceipt(parent,output:missing),for:parent) }
    missing["locationExtent"]="linkedContainment"
    let deeper = try await c.session.complete(compactDecision:CompactProductQueryPlanner.compile(continuationReceipt(parent,output:missing),for:parent),for:p,activeRequestID:p.requestID)
    #expect(!deeper.allRequestedValuesEstablished && deeper.rows[0].gaps.contains { $0.field == "venueLocation" })
    await c.f.close()
}
@Test func selectedContinuationHistoryBoundRefusesInsteadOfDroppingChain() async throws {
    let c = try await ContinuationControl()
    var focus: LinkedUnitContinuationContext?
    for i in 1...8 {
        let (a, _) = try await c.answer("Where is it?",focus:focus)
        focus = try await c.publish(a)
        #expect(focus?.publication.depth == i)
    }
    let (a, _) = try await c.answer("Where is it?",focus:focus)
    await continuationReject { _ = try await c.publish(a) }
    _ = try await c.session.admitDisplayedContinuation(focus!)
    await c.f.close()
}

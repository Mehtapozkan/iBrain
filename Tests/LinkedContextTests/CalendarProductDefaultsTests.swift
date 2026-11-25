import Foundation
import Testing
import IBrain
@testable import IBrainSemantics
import IBrainRetrieval

private func calendarPrepared(_ f: CalendarDefaultsFixture, parent: Bool = true) throws -> PreparedCompactProductQuestion {
    try CompactProductQueryPlanner.prepareCalendarDefaults(taskID: "AUTHORED-calendar-parent", inventory: f.inventory,
        contextual: parent ? f.child.task : nil, sources: f.sources)
}
private func calendarPayload(_ overrides: [String: Any] = [:]) -> [String: Any] {
    ["kind": "inventory", "operation": "list", "unit": "occurrences", "window": "today", "status": "all",
     "documentKind": "all", "clockBounds": [], "predicates": [], "requestedDetails": [], "evidenceFacets": []].merging(overrides) { _, new in new }
}
private func calendarReceipt(_ p: PreparedCompactProductQuestion, _ payload: [String: Any]) throws -> CompactProductQueryReceipt {
    let bytes = try JSONSerialization.data(withJSONObject: ["decision": payload], options: [.sortedKeys, .withoutEscapingSlashes])
    return .init(provider: "AUTHORED-OFFLINE", model: "NO-INFERENCE", requestSHA256: try p.task.digest(),
        outputJSON: String(decoding: bytes, as: UTF8.self), elapsedSeconds: 0)
}
private func calendarCompile(_ p: PreparedCompactProductQuestion, _ payload: [String: Any]) throws -> CompiledCompactProductQuestion {
    try CompactProductQueryPlanner.compile(calendarReceipt(p, payload), for: p)
}
private func calendarReject(_ operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Invalid or stale calendar operation admitted") } catch {}
}

@Suite struct CalendarProductDefaultsTests {
    @Test func fourPriorBuilderTaskBytesRemainExactlyV46() async throws {
        let f = try await CalendarDefaultsFixture()
        for (name, task) in try f.oldTasks() {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/CalendarDefaults"))
            #expect(try calendarCanonical(task) == Data(contentsOf: url))
        }
        await f.close()
    }

    @Test(arguments: [true, false])
    func policyIsExplicitAndBindsCurrentSourcesWithActualOfferedCapabilities(_ parent: Bool) async throws {
        let f = try await CalendarDefaultsFixture(), p = try calendarPrepared(f, parent: parent)
        let old = try f.oldTasks()[parent ? "member-parent" : "source-scope"]!
        let state = try JSONSerialization.jsonObject(with: Data(p.task.state.utf8)) as! [String: Any]
        let oldState = try JSONSerialization.jsonObject(with: Data(old.state.utf8)) as! [String: Any]
        let policy = state["calendarInventoryDefaults"] as! [String: Any]
        #expect(policy["unit"] as? String == "occurrences" && policy["status"] as? String == "all")
        #expect(policy["operation"] as? String == "list" && policy["documentKind"] as? String == "all")
        #expect(policy["inheritsDisplayedSubset"] as? Bool == false && policy["establishesIdentityOrOwnership"] as? Bool == false)
        #expect(p.task.version == "photo-product-query-compact-v3.2-calendar-defaults" && p.task.responseSchemaJSON == old.responseSchemaJSON)
        #expect(try JSONSerialization.data(withJSONObject: state["preparedState"]!, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: oldState["preparedState"]!, options: [.sortedKeys]))
        let scoped = try f.oldTasks()["source-scope"]!
        let scope = try JSONSerialization.jsonObject(with: Data(scoped.state.utf8)) as! [String: Any]
        #expect(try JSONSerialization.data(withJSONObject: state["currentSourceScope"]!, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: scope["currentSourceScope"]!, options: [.sortedKeys]))
        #expect(!p.task.instructions.contains("Choose unclear when this distinction cannot be settled"))
        #expect(p.task.instructions.contains("Explicit unit, count, status, kind, date/window"))
        #expect(p.task.instructions.contains("do not inherit its displayed subset"))
        #expect(!p.task.instructions.contains(f.input.question))
        await f.close()
    }

    /// These authored decisions test contract/native preservation, not what a
    /// model would choose. Natural-language semantic benefit remains unmeasured.
    @Test(arguments: ["naturalToday", "naturalWeek", "explicitCountUpcoming", "cancelledTickets", "scheduledAppointments", "clockAndPredicate"])
    func authoredNaturalAndExplicitMeaningsKeepEveryDimension(_ variant: String) async throws {
        let question: String
        var values: [String: Any] = [:]
        switch variant {
        case "naturalToday": question = "Anything today?"
        case "naturalWeek": question = "What is happening this week?"; values["window"] = "thisWeek"
        case "explicitCountUpcoming": question = "How many events are upcoming?"; values = ["operation": "count", "window": "upcoming"]
        case "cancelledTickets": question = "List cancelled tickets today with their addresses."; values = ["unit": "documents", "status": "cancelled", "documentKind": "eventTicket", "requestedDetails": ["venueAddress"]]
        case "scheduledAppointments": question = "List scheduled appointments tomorrow."; values = ["status": "scheduled", "window": "tomorrow", "documentKind": "appointment"]
        default: question = "Which tickets this week start after 9 PM and feature SCORPIONS, with their venue and street address?"; values = ["unit": "documents", "window": "thisWeek", "requestedDetails": ["venue", "venueAddress"]]
        }
        let f = try await CalendarDefaultsFixture(question: question), p = try calendarPrepared(f)
        if variant == "clockAndPredicate" {
            let key = try #require(f.inventory.questions["clock_0"]!.criteria.keys.sorted().first { $0.hasPrefix("after:") })
            let slot = String(key.dropFirst("after:".count))
            let word = try #require(f.inventory.questions["start_0"]!.criteria.first { $0.value == "SCORPIONS" }?.key)
            values["clockBounds"] = [["comparison": "after", "slot": slot]]
            values["predicates"] = [["field": "performer", "operator": "contains", "start": word, "end": word]]
        }
        let payload = calendarPayload(values), decision = try calendarCompile(p, payload)
        #expect(decision.route == .inventory)
        let plan = try ExhaustiveAppointmentPlanner.compile(compactDecision: decision, input: f.input, policy: .resultUnitsV4)
        #expect(plan.question == question && plan.resultUnit?.rawValue == payload["unit"] as? String)
        #expect(plan.operation.rawValue == payload["operation"] as? String && plan.window.id == payload["window"] as? String)
        #expect(plan.status == payload["status"] as? String && plan.kind == payload["documentKind"] as? String)
        #expect(plan.requestedDetails.map(\.rawValue).sorted() == (payload["requestedDetails"] as! [String]).sorted())
        if variant == "clockAndPredicate" { #expect(plan.clock.isRestricted && plan.predicates.count == 1 && plan.predicates[0].field == .performer) }
        let owner = ExhaustiveAppointmentSession(store: f.member.store), request = UUID()
        _ = try await owner.prepare(f.input, requestID: request, compactDecision: decision)
        let flat = try await owner.advance(activeRequestID: request)
        #expect(flat.plan.resultUnit?.rawValue == payload["unit"] as? String && flat.coverage.entireAdmittedInventory)
        #expect(flat.exactAdmittedCount == nil && !flat.requestedAnswerComplete)
        await f.close()
    }

    @Test func explicitDocumentsKeepMissingFieldsAndNoOccurrenceFallback() async throws {
        let f = try await CalendarDefaultsFixture(question: "List all tickets and their street addresses."), p = try calendarPrepared(f)
        let decision = try calendarCompile(p, calendarPayload(["unit": "documents", "window": "all", "requestedDetails": ["venueAddress"]]))
        let owner = ExhaustiveAppointmentSession(store: f.member.store), request = UUID()
        _ = try await owner.prepare(f.input, requestID: request, compactDecision: decision)
        let raw = try await owner.advance(activeRequestID: request)
        let answer = try await owner.inventoryUnitAnswer(raw, prepared: f.member.preparedDocuments, activeRequestID: request)
        #expect(answer.resultUnit == .documents && answer.exactCount == 2 && !answer.requestedAnswerComplete)
        #expect(answer.unresolvedFieldsByUnit.values.contains { $0.contains(.venueAddress) })
        await f.close()
    }

    @Test func genuineMemberOriginalAndDetailsSemanticsAreUnchanged() async throws {
        let f = try await CalendarDefaultsFixture(question: "What venue and street address are printed on the first ticket?"), p = try calendarPrepared(f)
        let decision = try calendarCompile(p, ["kind": "contextual", "operation": "details", "target": "unit_0_member_0", "requestedDetails": ["venue", "venueAddress"], "changeFields": "none", "evidenceFacets": [], "evidenceScope": "printedOwnSource"])
        let answer = try await f.linked.complete(compactDecision: decision, for: f.child, activeRequestID: f.child.requestID)
        #expect(answer.rows[0].answerMembers.map(\.recordID) == ["z-ticket-first"] && !answer.allRequestedValuesEstablished)
        #expect(answer.rows[0].scopedDetails!.allSatisfy { $0.value == nil && !$0.established })
        #expect(answer.currentOriginalSelections.isEmpty)
        let originals = try calendarCompile(p, ["kind": "contextual", "operation": "currentOriginals", "target": "unit_0", "requestedDetails": [], "changeFields": "none", "evidenceFacets": [], "evidenceScope": "currentSaved"])
        let opened = try await f.linked.complete(compactDecision: originals, for: f.child, activeRequestID: f.child.requestID)
        #expect(opened.currentOriginalSelections.count == 1 && opened.currentOriginalSelections[0].currentSources == Set(f.member.preparedDocuments.sources.map(\.reference)))
        await f.close()
    }

    @Test func noParentAndUnsupportedOrAmbiguousRequestsNeverManufactureContext() async throws {
        let f = try await CalendarDefaultsFixture(), p = try calendarPrepared(f, parent: false)
        #expect(!p.task.responseSchemaJSON.contains("allDisplayed") && !p.task.responseSchemaJSON.contains("printedOwnSource"))
        for route in ["clarify", "unknown", "unsupported"] {
            #expect(try calendarCompile(p, ["kind": route, "reason": "unit"]).route.rawValue == route)
        }
        let invalid: [[String: Any]] = [
            ["kind": "contextual", "operation": "currentOriginals", "target": "unit_0", "requestedDetails": [], "changeFields": "none", "evidenceFacets": [], "evidenceScope": "currentSaved"],
            calendarPayload(["unit": "photos"]), calendarPayload(["status": "upcoming"]),
            calendarPayload(["target": "unit_0"]), calendarPayload(["calendarInventoryDefaults": ["unit": "documents"]]),
            ["kind": "clarify", "reason": "unit", "unit": "occurrences"]]
        for value in invalid { #expect(throws: (any Error).self) { try calendarCompile(p, value) } }
        let old = try CompactProductQueryPlanner.prepare(taskID: "old", inventory: f.inventory, contextual: nil, permit: f.sources.permit, contract: .memberDetailsV3)
        let oldReceipt = try calendarReceipt(old, ["kind": "clarify", "reason": "unit"])
        #expect(try CompactProductQueryPlanner.compile(oldReceipt, for: old).route == .clarify)
        #expect(throws: (any Error).self) { try CompactProductQueryPlanner.compile(oldReceipt, for: p) }
        let wrongChild = ChoiceTask(id: f.child.task.id, state: f.child.task.state, questions: f.child.task.questions, version: "unsupported-context-version")
        #expect(throws: (any Error).self) { try CompactProductQueryPlanner.prepareCalendarDefaults(taskID: "bad", inventory: f.inventory, contextual: wrongChild, sources: f.sources) }
        await f.close()
    }

    @Test(arguments: ["clearParent", "withdrawal", "forget", "foreignStore"])
    func existingAdmissionFencesStaleParentAndSourceAuthority(_ variant: String) async throws {
        let f = try await CalendarDefaultsFixture(), p = try calendarPrepared(f)
        let decision = try calendarCompile(p, ["kind": "contextual", "operation": "details", "target": "unit_0_member_0", "requestedDetails": ["venue"], "changeFields": "none", "evidenceFacets": [], "evidenceScope": "printedOwnSource"])
        if variant == "clearParent" {
            try await f.member.owner.clearDisplayedUnitContext(f.member.context.id)
            await calendarReject { _ = try await f.linked.prepare(f.input, context: f.member.context, activeAnswerRequestID: f.member.parentID, requestID: UUID(), policy: .memberDetailsV3) }
        } else if variant == "foreignStore" {
            let other = try await CalendarDefaultsFixture()
            await calendarReject { try await decision.validateCurrentAuthority(in: other.member.store) }
            await calendarReject { _ = try await other.linked.complete(compactDecision: decision, for: other.child, activeRequestID: other.child.requestID) }
            await other.close(); await f.close(); return
        } else {
            try await f.member.store.invalidateSource(id: f.sources.sources[0].reference.id, forget: variant == "forget")
            await calendarReject { try await decision.validateCurrentAuthority(in: f.member.store) }
        }
        await calendarReject { _ = try await f.linked.complete(compactDecision: decision, for: f.child, activeRequestID: f.child.requestID) }
        await f.close()
    }

    @Test func realDocumentParentDoesNotBecomeTheNewCalendarUnitOrIdentityProof() async throws {
        let f = try await CalendarDefaultsFixture(), owner = ExhaustiveAppointmentSession(store: f.member.store), request = UUID()
        let old = try CompactProductQueryPlanner.prepare(taskID: "AUTHORED-document-parent", inventory: f.inventory,
            contextual: nil, permit: f.sources.permit, contract: .memberDetailsV3)
        let list = try calendarCompile(old, calendarPayload(["unit": "documents", "window": "all"]))
        _ = try await owner.prepare(f.input, requestID: request, compactDecision: list)
        let raw = try await owner.advance(activeRequestID: request)
        let docs = try await owner.inventoryUnitAnswer(raw, prepared: f.member.preparedDocuments, activeRequestID: request)
        let context = try await owner.contextForDisplayedInventoryUnitAnswer(docs, activeRequestID: request, displayedUnitIDs: docs.orderedUnits.map(\.id))
        let input = MemberContractFixture.input(context, "Anything today?"), linked = try LinkedUnitQuestionSession(store: f.member.store, unitOwner: owner)
        let child = try await linked.prepare(input, context: context, activeAnswerRequestID: request, requestID: UUID(), policy: .memberDetailsV3)
        let inventory = try ExhaustiveAppointmentPlanner.task(input, policy: .resultUnitsV4)
        let p = try CompactProductQueryPlanner.prepareCalendarDefaults(taskID: "AUTHORED-calendar-after-docs", inventory: inventory, contextual: child.task, sources: f.sources)
        let decision = try calendarCompile(p, calendarPayload())
        let plan = try ExhaustiveAppointmentPlanner.compile(compactDecision: decision, input: input, policy: .resultUnitsV4)
        #expect(context.resultUnit == .documents && context.orderedRows.count == 2 && plan.resultUnit == .occurrences)
        let newOwner = ExhaustiveAppointmentSession(store: f.member.store), newRequest = UUID()
        _ = try await newOwner.prepare(input, requestID: newRequest, compactDecision: decision)
        let newRaw = try await newOwner.advance(activeRequestID: newRequest)
        #expect(newRaw.exactAdmittedCount == nil && !newRaw.requestedAnswerComplete)
        await calendarReject { _ = try await newOwner.inventoryUnitAnswer(newRaw, prepared: f.member.preparedDocuments, activeRequestID: newRequest) }
        await f.close()
    }

    @Test(arguments: ["revision", "fingerprint"])
    func sourceCatalogChangesBindNewTaskAndInvalidateOldDecision(_ variant: String) async throws {
        let f = try await CalendarDefaultsFixture(), p = try calendarPrepared(f, parent: false)
        let decision = try calendarCompile(p, calendarPayload())
        let old = f.sources.sources[0], ref = old.reference
        let source = SourceSnapshot(reference: .init(id: ref.id, revision: variant == "revision" ? ref.revision + 1 : ref.revision,
            fingerprint: variant == "fingerprint" ? "AUTHORED-new-pixels" : ref.fingerprint), scope: old.scope, observations: old.observations)
        try await f.member.store.synchronize(.init(sources: [source], records: []))
        await calendarReject { try await decision.validateCurrentAuthority(in: f.member.store) }
        let sources = try await f.member.store.sourceSearchSnapshot(permit: f.member.store.permit())
        let current = try CompactProductQueryPlanner.prepareCalendarDefaults(taskID: p.task.id, inventory: f.inventory, contextual: nil, sources: sources)
        #expect(try current.task.digest() != p.task.digest())
        #expect(!current.task.responseSchemaJSON.contains("allDisplayed"))
        await f.close()
    }
}

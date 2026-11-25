import Foundation
import Testing
import IBrain
@testable import IBrainSemantics
import IBrainRetrieval

private func photoCalendar(_ f: CalendarDefaultsFixture, parent: Bool = true) throws -> PreparedCompactProductQuestion {
    try CompactProductQueryPlanner.preparePhotoCalendarDefaults(taskID: "AUTHORED-photo-calendar", inventory: f.inventory,
        contextual: parent ? f.child.task : nil, sources: f.sources)
}
private func photoPayload(_ overrides: [String: Any] = [:]) -> [String: Any] {
    ["kind": "inventory", "operation": "list", "unit": "documents", "window": "all", "status": "all",
     "documentKind": "all", "clockBounds": [], "predicates": [], "requestedDetails": [], "evidenceFacets": []].merging(overrides) { _, new in new }
}
private func photoReceipt(_ p: PreparedCompactProductQuestion, _ payload: [String: Any]) throws -> CompactProductQueryReceipt {
    let data = try JSONSerialization.data(withJSONObject: ["decision": payload], options: [.sortedKeys, .withoutEscapingSlashes])
    return .init(provider: "AUTHORED-OFFLINE", model: "NO-INFERENCE", requestSHA256: try p.task.digest(),
        outputJSON: String(decoding: data, as: UTF8.self), elapsedSeconds: 0)
}
private func photoCompile(_ p: PreparedCompactProductQuestion, _ payload: [String: Any]) throws -> CompiledCompactProductQuestion {
    try CompactProductQueryPlanner.compile(photoReceipt(p, payload), for: p)
}
private func photoObject(_ text: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
}
private func photoJSON(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}
private func photoReject(_ operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Invalid or stale photo/calendar authority admitted") } catch {}
}

@Suite struct PhotoCalendarCompositionTests {
    @Test(arguments: [true, false])
    func oldV47WireBytesStayFrozenWhileBothMeaningsAreComposed(_ parent: Bool) async throws {
        let f = try await CalendarDefaultsFixture(), p = try photoCalendar(f, parent: parent)
        let old = try CompactProductQueryPlanner.prepareCalendarDefaults(taskID: "AUTHORED-photo-calendar", inventory: f.inventory,
            contextual: parent ? f.child.task : nil, sources: f.sources)
        let golden = try #require(Bundle.module.url(forResource: "calendar-" + String(parent), withExtension: "json", subdirectory: "Fixtures/PhotoCalendarV47"))
        #expect(try calendarCanonical(old.task) == Data(contentsOf: golden))
        let state = try photoObject(p.task.state), oldState = try photoObject(old.task.state)
        #expect(p.task.version == "photo-product-query-compact-v3.3-photo-calendar-defaults")
        #expect(p.task.responseSchemaJSON == old.task.responseSchemaJSON)
        for key in ["preparedState", "currentSourceScope", "calendarInventoryDefaults"] {
            #expect(try photoJSON(state[key]!) == photoJSON(oldState[key]!))
        }
        let policy = state["photoScopePolicy"] as! [String: Any]
        #expect(policy["contextualBranchAvailable"] as? Bool == parent)
        #expect(policy["broadDocumentOverviewUnit"] as? String == "documents")
        #expect(p.task.instructions.components(separatedBy: "PHOTO INPUT SCOPE: ").count == 2)
        #expect(p.task.instructions.contains("MEMBER CONTRACT:") == parent)
        #expect(p.task.instructions.contains("Do not apply calendar defaults merely because source or displayed text mentions a date"))
        #expect(!p.task.instructions.contains(f.input.question))
        #expect(try p.task.digest() != old.task.digest())
        await f.close()
    }

    /// Authored meanings exercise native preservation; no language-accuracy
    /// result is inferred from these illustrative neighboring questions.
    @Test(arguments: ["overview", "paraphrase", "today", "eventsCount", "ticketsRestricted", "overviewDates"])
    func neighboringAuthoredMeaningsPreserveUnitsAndEveryRestriction(_ variant: String) async throws {
        let question: String
        var values: [String: Any] = [:]
        switch variant {
        case "overview": question = "Give me an overview of the documented contents of these pictures."
        case "paraphrase": question = "Summarise whats shown on the tickets in my photos."
        case "today": question = "Any plans today?"; values = ["unit": "occurrences", "window": "today"]
        case "eventsCount": question = "How many performances are represented by these tickets?"; values = ["unit": "occurrences", "operation": "count"]
        case "ticketsRestricted": question = "List cancelled tickets this week after 9 PM, excluding SCORPIONS, with the street address."; values = ["window": "thisWeek", "status": "cancelled", "documentKind": "eventTicket", "requestedDetails": ["venueAddress"]]
        default: question = "Describe the ticket contents, including their dates."; values = ["requestedDetails": ["localDate"]]
        }
        let f = try await CalendarDefaultsFixture(question: question), p = try photoCalendar(f)
        #expect(f.member.context.resultUnit == .occurrences)
        if variant == "ticketsRestricted" {
            let clock = try #require(f.inventory.questions["clock_0"]!.criteria.keys.sorted().first { $0.hasPrefix("after:") })
            let word = try #require(f.inventory.questions["start_0"]!.criteria.first { $0.value == "SCORPIONS" }?.key)
            values["clockBounds"] = [["comparison": "after", "slot": String(clock.dropFirst("after:".count))]]
            values["predicates"] = [["field": "performer", "operator": "excludes", "start": word, "end": word]]
        }
        let payload = photoPayload(values), decision = try photoCompile(p, payload)
        let plan = try ExhaustiveAppointmentPlanner.compile(compactDecision: decision, input: f.input, policy: .resultUnitsV4)
        #expect(plan.resultUnit?.rawValue == payload["unit"] as? String)
        #expect(plan.operation.rawValue == payload["operation"] as? String && plan.window.id == payload["window"] as? String)
        #expect(plan.status == payload["status"] as? String && plan.kind == payload["documentKind"] as? String)
        #expect(plan.requestedDetails.map(\.rawValue).sorted() == (payload["requestedDetails"] as! [String]).sorted())
        if variant == "ticketsRestricted" { #expect(plan.clock.isRestricted && plan.predicates.count == 1 && plan.predicates[0].field == .performer) }
        let owner = ExhaustiveAppointmentSession(store: f.member.store), request = UUID()
        _ = try await owner.prepare(f.input, requestID: request, compactDecision: decision)
        let flat = try await owner.advance(activeRequestID: request)
        #expect(flat.coverage.entireAdmittedInventory)
        if plan.resultUnit == .documents {
            let docs = try await owner.inventoryUnitAnswer(flat, prepared: f.member.preparedDocuments, activeRequestID: request)
            #expect(docs.resultUnit == .documents)
            if variant == "overview" || variant == "paraphrase" || variant == "overviewDates" { #expect(docs.exactCount == 2) }
        } else {
            #expect(flat.exactAdmittedCount == nil && !flat.requestedAnswerComplete)
            await photoReject { _ = try await owner.inventoryUnitAnswer(flat, prepared: f.member.preparedDocuments, activeRequestID: request) }
        }
        await f.close()
    }

    @Test(arguments: ["Show the tickets and count all the people in the photos.", "How many photos did I take?", "Compare ticket prices to my invoices.", "Which of those displayed events starts after 8 PM?"])
    func mixedOrUnsupportedMeaningsRetainNoExecutionWithoutDroppingClauses(_ question: String) async throws {
        let f = try await CalendarDefaultsFixture(question: question), p = try photoCalendar(f)
        let decision = try photoCompile(p, ["kind": "unsupported", "reason": "restriction"])
        #expect(decision.route == .unsupported)
        #expect(throws: (any Error).self) { try ExhaustiveAppointmentPlanner.compile(compactDecision: decision, input: f.input, policy: .resultUnitsV4) }
        #expect(p.task.instructions.contains("including mixed supported and unsupported requests"))
        #expect(p.task.instructions.contains("previous-subset filters/counts remain unsupported"))
        #expect(throws: (any Error).self) { try photoCompile(p, photoPayload(["unit": "photos"])) }
        await f.close()
    }

    @Test func genuineMemberDetailsAndWholeOriginalsRetainExactParentAuthority() async throws {
        let f = try await CalendarDefaultsFixture(question: "What venue is printed on the first ticket?"), p = try photoCalendar(f)
        let details = try photoCompile(p, ["kind": "contextual", "operation": "details", "target": "unit_0_member_0", "requestedDetails": ["venue"], "changeFields": "none", "evidenceFacets": [], "evidenceScope": "printedOwnSource"])
        let answer = try await f.linked.complete(compactDecision: details, for: f.child, activeRequestID: f.child.requestID)
        #expect(answer.rows[0].answerMembers.map(\.recordID) == ["z-ticket-first"] && !answer.allRequestedValuesEstablished)
        let originals = try photoCompile(p, ["kind": "contextual", "operation": "currentOriginals", "target": "unit_0", "requestedDetails": [], "changeFields": "none", "evidenceFacets": [], "evidenceScope": "currentSaved"])
        let selection = try await f.linked.complete(compactDecision: originals, for: f.child, activeRequestID: f.child.requestID)
        #expect(selection.currentOriginalSelections.count == 1)
        #expect(selection.currentOriginalSelections[0].currentSources == Set(f.sources.sources.map(\.reference)))
        let noParent = try photoCalendar(f, parent: false)
        #expect(throws: (any Error).self) { try photoCompile(noParent, ["kind": "contextual", "operation": "currentOriginals", "target": "unit_0", "requestedDetails": [], "changeFields": "none", "evidenceFacets": [], "evidenceScope": "currentSaved"]) }
        try await f.member.owner.clearDisplayedUnitContext(f.member.context.id)
        await photoReject { _ = try await f.linked.complete(compactDecision: originals, for: f.child, activeRequestID: f.child.requestID) }
        await f.close()
    }

    @Test(arguments: ["forget", "revision", "foreign"])
    func existingSourceAndStoreFencesRemainInForce(_ variant: String) async throws {
        let f = try await CalendarDefaultsFixture(), p = try photoCalendar(f), decision = try photoCompile(p, photoPayload())
        if variant == "foreign" {
            let other = try await CalendarDefaultsFixture()
            await photoReject { try await decision.validateCurrentAuthority(in: other.member.store) }
            await other.close()
        } else {
            if variant == "forget" { try await f.member.store.invalidateSource(id: f.sources.sources[0].reference.id, forget: true) }
            else {
                let source = f.sources.sources[0], ref = source.reference
                let changed = SourceSnapshot(reference: .init(id: ref.id, revision: ref.revision + 1, fingerprint: ref.fingerprint), scope: source.scope, observations: source.observations)
                try await f.member.store.synchronize(.init(sources: [changed], records: []))
            }
            await photoReject { try await decision.validateCurrentAuthority(in: f.member.store) }
        }
        await f.close()
    }

    @Test func oldReceiptsAndExtraPolicyFieldsCannotBeReboundToNewWire() async throws {
        let f = try await CalendarDefaultsFixture(), p = try photoCalendar(f)
        let old = try CompactProductQueryPlanner.prepareCalendarDefaults(taskID: p.task.id, inventory: f.inventory, contextual: f.child.task, sources: f.sources)
        #expect(throws: (any Error).self) { try CompactProductQueryPlanner.compile(photoReceipt(old, photoPayload()), for: p) }
        #expect(throws: (any Error).self) { try CompactProductQueryPlanner.compile(photoReceipt(p, photoPayload()), for: old) }
        #expect(throws: (any Error).self) { try photoCompile(p, photoPayload(["photoScopePolicy": [:]])) }
        let wrong = ChoiceTask(id: f.child.task.id, state: f.child.task.state, questions: f.child.task.questions, version: "wrong-context-version")
        #expect(throws: (any Error).self) { try CompactProductQueryPlanner.preparePhotoCalendarDefaults(taskID: p.task.id, inventory: f.inventory, contextual: wrong, sources: f.sources) }
        for kind in ["clarify", "unknown", "unsupported"] { #expect(try photoCompile(p, ["kind": kind, "reason": "meaning"]).route.rawValue == kind) }
        await f.close()
    }
}

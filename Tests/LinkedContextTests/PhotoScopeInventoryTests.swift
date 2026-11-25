import Foundation
import Testing
import IBrain
@testable import IBrainSemantics
import IBrainRetrieval

private func photoScopeReceipt(_ prepared: PreparedCompactProductQuestion, _ decision: [String: Any]) throws -> CompactProductQueryReceipt {
    let data = try JSONSerialization.data(withJSONObject: ["decision": decision], options: [.sortedKeys, .withoutEscapingSlashes])
    return .init(provider: "AUTHORED-OFFLINE-CONTROL", model: "NO-INFERENCE", requestSHA256: try prepared.task.digest(), outputJSON: String(decoding: data, as: UTF8.self), elapsedSeconds: 0)
}

private func photoScopeInventory(_ overrides: [String: Any] = [:]) -> [String: Any] {
    let base: [String: Any] = ["kind": "inventory", "operation": "list", "unit": "documents", "window": "all", "status": "all", "documentKind": "all", "clockBounds": [], "predicates": [], "requestedDetails": [], "evidenceFacets": []]
    return base.merging(overrides) { _, new in new }
}

private func photoScopeTask(_ fixture: MemberContractFixture, _ question: String) async throws -> PreparedCompactProductQuestion {
    try CompactProductQueryPlanner.prepare(taskID: "photo-scope-control", inventory: ExhaustiveAppointmentPlanner.task(MemberContractFixture.input(nil, question), policy: .resultUnitsV4), contextual: nil, permit: await fixture.store.permit(), contract: .photoScopeInventoryV22)
}

@Suite struct PhotoScopeInventoryTests {
    @Test func retainedPhoneFailureAndLegacyTaskRemainExact() async throws {
        let fixture = try await MemberContractFixture()
        let taskURL = try #require(Bundle.module.url(forResource: "PHONE-BROAD-V2-TASK", withExtension: "json", subdirectory: "Fixtures"))
        let receiptURL = try #require(Bundle.module.url(forResource: "PHONE-BROAD-V2-RECEIPT", withExtension: "json", subdirectory: "Fixtures"))
        let frozen = try JSONDecoder().decode(CompactProductQueryTask.self, from: Data(contentsOf: taskURL))
        let oldReceipt = try JSONDecoder().decode(CompactProductQueryReceipt.self, from: Data(contentsOf: receiptURL))
        let state = try JSONSerialization.jsonObject(with: Data(frozen.state.utf8)) as! [String: Any]
        let branches = (state["preparedState"] as! [String: Any])["branches"] as! [String: Any]
        let child = branches["inventory"] as! [String: Any]
        let nativeState = child["state"] as! [String: Any]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: nativeState["calendarZone"] as! String))
        calendar.firstWeekday = nativeState["firstWeekday"] as! Int
        calendar.minimumDaysInFirstWeek = nativeState["minimumDaysInFirstWeek"] as! Int
        let input = EvidenceQuestionInput(taskID: child["taskID"] as! String, question: nativeState["question"] as! String, now: try #require(ISO8601DateFormatter().date(from: nativeState["now"] as! String)), calendar: calendar)
        let inventory = try ExhaustiveAppointmentPlanner.task(input, policy: .resultUnitsV4)
        let permit = try await fixture.store.permit()
        let old = try CompactProductQueryPlanner.prepare(taskID: frozen.id, inventory: inventory, contextual: nil, permit: permit, contract: .linkedUnitContextV2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        #expect(try encoder.encode(old.task) == encoder.encode(frozen))
        let oldDecision = try CompactProductQueryPlanner.compile(oldReceipt, for: old)
        #expect(oldDecision.route == .clarify && oldDecision.reason == "target")
        let revised = try CompactProductQueryPlanner.prepare(taskID: frozen.id, inventory: inventory, contextual: nil, permit: permit, contract: .photoScopeInventoryV22)
        #expect(revised.task.responseSchemaJSON == frozen.responseSchemaJSON)
        #expect(revised.task.version == "photo-product-query-compact-v2.2-photo-scope-inventory")
        #expect(!revised.task.instructions.contains("The opt-in contextual branch"))
        #expect(!revised.task.instructions.contains("A request for photos, people, seats"))
        #expect(revised.task.instructions.contains("no previously displayed answer or selected result target"))
        #expect(!revised.task.state.contains("Both branches were prepared"))
        #expect(!revised.task.state.contains("Lens fitting") && !revised.task.state.contains("Low Tide Sessions"))
        #expect(throws: (any Error).self) { try CompactProductQueryPlanner.compile(oldReceipt, for: revised) }
        let authored = try photoScopeReceipt(revised, photoScopeInventory())
        #expect(throws: (any Error).self) { try CompactProductQueryPlanner.compile(authored, for: old) }
        // An authored replacement still permits genuine clarification. No compiler forces inventory.
        #expect(try CompactProductQueryPlanner.compile(photoScopeReceipt(revised, ["kind": "clarify", "reason": "target"]), for: revised).route == .clarify)
        if let path = ProcessInfo.processInfo.environment["IBRAIN_PHOTO_SCOPE_ARTIFACT_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(revised.task).write(to: directory.appendingPathComponent("REPAIRED-EXACT-QUESTION-TASK.json"))
            try encoder.encode(authored).write(to: directory.appendingPathComponent("AUTHORED-OVERVIEW-RECEIPT.json"))
        }
        await fixture.close()
    }

    @Test(arguments: ["What is in these photos", "What do these pictures document?", "Give me an overview of the documents in these images.", "Tell me what the photographed confirmations contain.", "Whats in these photso?", "Summarise the tickets and appointment confirmations shown here."])
    func authoredOverviewParaphrasesRetainFullQuestionAndNativeDocuments(_ question: String) async throws {
        let fixture = try await MemberContractFixture()
        let prepared = try await photoScopeTask(fixture, question)
        let state = try JSONSerialization.jsonObject(with: Data(prepared.task.state.utf8)) as! [String: Any]
        let policy = state["photoScopePolicy"] as! [String: Any]
        #expect(policy["contextualBranchAvailable"] as? Bool == false)
        #expect(policy["broadDocumentOverviewUnit"] as? String == "documents")
        #expect(prepared.task.state.contains(question))
        #expect(!prepared.task.state.contains("SCORPIONS") && !prepared.task.state.contains("ARENA ARMEEC"))
        let decision = try CompactProductQueryPlanner.compile(photoScopeReceipt(prepared, photoScopeInventory()), for: prepared)
        let session = ExhaustiveAppointmentSession(store: fixture.store)
        let request = UUID()
        _ = try await session.prepare(MemberContractFixture.input(nil, question), requestID: request, compactDecision: decision)
        let records = try await session.advance(activeRequestID: request)
        let answer = try await session.inventoryUnitAnswer(records, prepared: fixture.preparedDocuments, activeRequestID: request)
        #expect(answer.resultUnit == .documents && answer.exactCount == 2)
        #expect(answer.orderedUnits.flatMap(\.members).count == 2)
        #expect(answer.queryReceipt.compactProductQueryReceipt == decision.originalReceipt)
        await fixture.close()
    }

    @Test(arguments: [
        ("How many photos are there?", "unsupported", "unit"),
        ("Count the people in these photos.", "unsupported", "unit"),
        ("How many seats do I have?", "unsupported", "unit"),
        ("Identify the yellow sneakers and their store.", "unsupported", "meaning"),
        ("List the tickets and identify everyone in the pictures.", "unsupported", "meaning"),
        ("When does it start?", "clarify", "target"),
        ("Show the second one.", "clarify", "target"),
        ("Describe the two other photos I meant.", "clarify", "target"),
        ("I cannot decide what I meant.", "unknown", "meaning")
    ])
    func authoredUnsupportedAndAmbiguousNeighborsRemainNoExecution(_ question: String, _ route: String, _ reason: String) async throws {
        let fixture = try await MemberContractFixture()
        let prepared = try await photoScopeTask(fixture, question)
        #expect(prepared.task.state.contains(question))
        let decision = try CompactProductQueryPlanner.compile(photoScopeReceipt(prepared, ["kind": route, "reason": reason]), for: prepared)
        #expect(decision.route.rawValue == route && decision.reason == reason)
        #expect(throws: (any Error).self) { try ExhaustiveAppointmentPlanner.compile(compactDecision: decision, input: MemberContractFixture.input(nil, question), policy: .resultUnitsV4) }
        await fixture.close()
    }

    @Test func explicitCountWindowDetailsAndEventUnitSurvive() async throws {
        let fixture = try await MemberContractFixture()
        let question = "Count every concert next week starting after 9 PM, with artist and venue address, including cancelled ones."
        let input = MemberContractFixture.input(nil, question)
        let inventory = try ExhaustiveAppointmentPlanner.task(input, policy: .resultUnitsV4)
        let clock = try #require(inventory.questions["clock_0"]?.criteria.keys.first { $0.hasPrefix("after:") })
        let prepared = try await photoScopeTask(fixture, question)
        let output = photoScopeInventory(["operation": "count", "unit": "occurrences", "window": "nextWeek", "status": "all", "documentKind": "eventTicket", "clockBounds": [["comparison": "after", "slot": String(clock.split(separator: ":")[1])]], "requestedDetails": ["performer", "venueAddress"]])
        let decision = try CompactProductQueryPlanner.compile(photoScopeReceipt(prepared, output), for: prepared)
        let plan = try ExhaustiveAppointmentPlanner.compile(compactDecision: decision, input: input, policy: .resultUnitsV4)
        #expect(plan.operation == .count && plan.resultUnit == .occurrences)
        #expect(plan.question == question && plan.requestedDetails == [.performer, .venueAddress])
        #expect(plan.window.id == "nextWeek" && plan.status == "all" && plan.kind == "eventTicket")
        #expect(plan.clock.isRestricted && plan.clock.lowerMinute == 21 * 60 + 1 && plan.clock.upperMinute == 1439)
        #expect(plan.receipt.compactProductQueryReceipt == decision.originalReceipt)
        await fixture.close()
    }

    @Test func explicitNegativeLiteralAndCancellationFacetSurvive() async throws {
        let fixture = try await MemberContractFixture()
        let question = "List cancelled tickets excluding Silver Finch with venue and cancellation evidence."
        let input = MemberContractFixture.input(nil, question)
        let inventory = try ExhaustiveAppointmentPlanner.task(input, policy: .resultUnitsV4)
        let words = try #require(inventory.questions["start_0"]?.criteria)
        let start = try #require(words.first { $0.value == "Silver" }?.key)
        let end = try #require(words.first { $0.value == "Finch" }?.key)
        let prepared = try await photoScopeTask(fixture, question)
        let output = photoScopeInventory(["status": "cancelled", "documentKind": "eventTicket", "predicates": [["field": "performer", "operator": "excludes", "start": start, "end": end]], "requestedDetails": ["venue"], "evidenceFacets": ["documentedStatus"]])
        let decision = try CompactProductQueryPlanner.compile(photoScopeReceipt(prepared, output), for: prepared)
        let plan = try ExhaustiveAppointmentPlanner.compile(compactDecision: decision, input: input, policy: .resultUnitsV4)
        #expect(plan.resultUnit == .documents && plan.status == "cancelled" && plan.kind == "eventTicket")
        #expect(plan.predicates.count == 1 && plan.predicates[0].questionQuote == "Silver Finch")
        #expect(plan.predicates[0].operation == .excludes && plan.predicates[0].field == .performer)
        #expect(plan.requestedDetails == [.venue] && plan.requestedSourceEvidence == [.documentedStatus])
        await fixture.close()
    }

    @Test(arguments: ["photos", "people", "seats"])
    func unsupportedUnitsCannotEnterInventoryWire(_ unit: String) async throws {
        let fixture = try await MemberContractFixture()
        let prepared = try await photoScopeTask(fixture, "Count the requested objects in these photos.")
        let invalid = photoScopeInventory(["operation": "count", "unit": unit])
        #expect(throws: (any Error).self) { try CompactProductQueryPlanner.compile(photoScopeReceipt(prepared, invalid), for: prepared) }
        await fixture.close()
    }

    @Test func strictPayloadAndMissingContextValidationRemain() async throws {
        let fixture = try await MemberContractFixture()
        let prepared = try await photoScopeTask(fixture, "What do these documents show?")
        let invalidOutputs = [
            photoScopeInventory(["target": "allPhotos"]),
            photoScopeInventory(["photoIDs": ["invented-source"]]),
            photoScopeInventory(["operation": "delete"]),
            photoScopeInventory(["requestedDetails": ["performer", "performer"]]),
            photoScopeInventory(["clockBounds": [["comparison": "after", "slot": "invented"]]]),
            photoScopeInventory(["predicates": [["field": "person", "operator": "contains", "start": "w0", "end": "w0"]]]),
            ["kind": "contextual", "operation": "details", "target": "unit_0", "requestedDetails": ["venue"], "changeFields": "none", "evidenceFacets": []]
        ]
        for invalid in invalidOutputs {
            #expect(throws: (any Error).self) { try CompactProductQueryPlanner.compile(photoScopeReceipt(prepared, invalid), for: prepared) }
        }
        let valid = try CompactProductQueryPlanner.compile(photoScopeReceipt(prepared, photoScopeInventory()), for: prepared)
        try await fixture.store.invalidateSource(id: "AUTHORED-two-ticket-photo", forget: true)
        do {
            try await valid.validateCurrentAuthority(in: fixture.store)
            Issue.record("Withdrawn authority was accepted")
        } catch {}
        await fixture.close()
    }

    @Test func suppliedContextStillSupportsLinkedDetailsAndStandaloneInventory() async throws {
        let fixture = try await MemberContractFixture()
        let question = "Give the displayed concert's venue address."
        let input = MemberContractFixture.input(fixture.context, question)
        let session = try LinkedUnitQuestionSession(store: fixture.store, unitOwner: fixture.owner)
        let child = try await session.prepare(input, context: fixture.context, activeAnswerRequestID: fixture.parentID, requestID: UUID())
        let prepared = try CompactProductQueryPlanner.prepare(taskID: "photo-scope-with-context", inventory: ExhaustiveAppointmentPlanner.task(input, policy: .resultUnitsV4), contextual: child.task, permit: await fixture.store.permit(), contract: .photoScopeInventoryV22)
        #expect(prepared.task.instructions.contains("Only when kind=contextual: contextual target"))
        let contextOutput: [String: Any] = ["kind": "contextual", "operation": "details", "target": "unit_0", "requestedDetails": ["venueAddress"], "changeFields": "none", "evidenceFacets": []]
        let decision = try CompactProductQueryPlanner.compile(photoScopeReceipt(prepared, contextOutput), for: prepared)
        #expect(decision.route == .contextual)
        #expect(try decision.contextualChoice("target", for: child.task) == "unit_0")
        let inventory = try CompactProductQueryPlanner.compile(photoScopeReceipt(prepared, photoScopeInventory()), for: prepared)
        #expect(inventory.route == .inventory)
        await fixture.close()
    }
}

import Foundation
import Testing
import IBrain
import IBrainSemantics
import IBrainRetrieval

private struct SurvivorPreparation: Decodable {
    struct Authority: Decodable {
        struct Record: Decodable {
            struct Observation: Decodable { let sourceValueProof: Data }
            let observation: Observation
        }
        let sdkMemory: Data
        let records: [Record]
    }
    let authority: Authority
    let now: Date
    let question: String
}

private struct SurvivorSnapshot: Decodable {
    struct Row: Decodable { let projection: MemoryProjection }
    let scope: MemoryScope
    let rows: [String: Row]
}

private struct SurvivorValueProof: Decodable {
    struct Context: Decodable { let source: SourceSnapshot }
    let context: Context
}

private struct SurvivorFixture {
    let directory: URL
    let store: MemoryStore
    let input: EvidenceQuestionInput
    let originalTask: CompactProductQueryTask
    let originalReceipt: CompactProductQueryReceipt
    let originalSource: SourceSnapshot

    init(sourceCount: Int = 1) async throws {
        let resource = try #require(Bundle.module.url(forResource: "forget-preparation", withExtension: "json", subdirectory: "Fixtures/CurrentSourceScope"))
        let folder = resource.deletingLastPathComponent()
        let decoder = JSONDecoder()
        let preparation = try decoder.decode(SurvivorPreparation.self, from: Data(contentsOf: resource))
        let snapshot = try decoder.decode(SurvivorSnapshot.self, from: preparation.authority.sdkMemory)
        originalTask = try decoder.decode(CompactProductQueryTask.self, from: Data(contentsOf: folder.appendingPathComponent("forget-task.json")))
        struct HostResult: Decodable { let response: CompactProductQueryReceipt }
        originalReceipt = try decoder.decode(HostResult.self, from: Data(contentsOf: folder.appendingPathComponent("forget-host-result.json"))).response
        originalSource = try decoder.decode(SurvivorValueProof.self, from: preparation.authority.records[0].observation.sourceValueProof).context.source
        let projections = snapshot.rows.values.map(\.projection)
        #expect(projections.count == 1 && originalSource.reference.revision == 3)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("current-source-scope-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try preparation.authority.sdkMemory.write(to: directory.appendingPathComponent("memory.json"))
        store = try MemoryStore(directory: directory, scope: snapshot.scope)
        var sources = sourceCount == 0 ? [] : [originalSource]
        if sourceCount == 2 {
            sources.append(.init(reference: .init(id: "AUTHORED-extra-current-source", revision: 1, fingerprint: "AUTHORED-NO-PIXELS"), scope: snapshot.scope, observations: [.init(id: "scope-control", value: "AUTHORED source without a booking projection")]))
        }
        let records = sourceCount == 0 ? [] : projections.map { DomainRecordPin(id: $0.recordID, revision: $0.recordRevision, sources: $0.sources) }
        try await store.synchronize(.init(sources: sources, records: records))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = 1
        calendar.minimumDaysInFirstWeek = 1
        input = .init(taskID: "pin-exhaustive-question", question: preparation.question, now: preparation.now, calendar: calendar)
    }

    func legacyTask() async throws -> PreparedCompactProductQuestion {
        try CompactProductQueryPlanner.prepare(taskID: originalTask.id, inventory: ExhaustiveAppointmentPlanner.task(input, policy: .resultUnitsV4), contextual: nil, permit: await store.permit(), contract: .photoScopeInventoryV22)
    }

    func scopedTask(_ question: String? = nil) async throws -> PreparedCompactProductQuestion {
        let request = EvidenceQuestionInput(taskID: input.taskID, question: question ?? input.question, now: input.now, calendar: input.calendar)
        return try CompactProductQueryPlanner.prepareCurrentSourceScope(taskID: originalTask.id, inventory: ExhaustiveAppointmentPlanner.task(request, policy: .resultUnitsV4), sources: await store.sourceSearchSnapshot(permit: store.permit()))
    }

    func close() async {
        await store.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func scopedReceipt(_ prepared: PreparedCompactProductQuestion, _ decision: [String: Any]) throws -> CompactProductQueryReceipt {
    let bytes = try JSONSerialization.data(withJSONObject: ["decision": decision], options: [.sortedKeys, .withoutEscapingSlashes])
    return .init(provider: "AUTHORED-CURRENT-SCOPE-CONTROL", model: "NO-INFERENCE", requestSHA256: try prepared.task.digest(), outputJSON: String(decoding: bytes, as: UTF8.self), elapsedSeconds: 0)
}

private func scopedInventory(_ overrides: [String: Any] = [:]) -> [String: Any] {
    let base: [String: Any] = ["kind": "inventory", "operation": "list", "unit": "documents", "window": "all", "status": "all", "documentKind": "all", "clockBounds": [], "predicates": [], "requestedDetails": [], "evidenceFacets": []]
    return base.merging(overrides) { _, next in next }
}

@Suite struct CurrentSourceScopeTests {
    @Test func retainedDefaultOmitsScopeAcrossDifferentCurrentCatalogs() async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var oldDigests: [String] = []
        var newDigests: [String] = []
        var contrast: [[String: Any]] = []
        for count in [0, 1, 2] {
            let fixture = try await SurvivorFixture(sourceCount: count)
            let old = try await fixture.legacyTask()
            #expect(try encoder.encode(old.task) == encoder.encode(fixture.originalTask))
            let decision = try CompactProductQueryPlanner.compile(fixture.originalReceipt, for: old)
            #expect(decision.route == .clarify && decision.reason == "target")
            oldDigests.append(try old.task.digest())
            let current = try await fixture.scopedTask()
            let state = try JSONSerialization.jsonObject(with: Data(current.task.state.utf8)) as! [String: Any]
            let scope = state["currentSourceScope"] as! [String: Any]
            #expect(scope["sourceCount"] as? Int == count)
            #expect((scope["bindingSHA256"] as? String)?.count == 64)
            #expect(current.task.responseSchemaJSON == old.task.responseSchemaJSON)
            #expect(!current.task.state.contains("LARCH OPTICAL STUDIO") && !current.task.state.contains("2026-11-04"))
            #expect(!current.task.state.contains(fixture.originalSource.reference.id))
            newDigests.append(try current.task.digest())
            contrast.append(["sourceCount": count, "legacyRequestSHA256": try old.task.digest(), "boundRequestSHA256": try current.task.digest(), "sourceBindingSHA256": scope["bindingSHA256"]!])
            #expect(throws: (any Error).self) { try CompactProductQueryPlanner.compile(fixture.originalReceipt, for: current) }
            if count == 1, let output = ProcessInfo.processInfo.environment["IBRAIN_CURRENT_SCOPE_ARTIFACT_DIR"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try encoder.encode(current.task).write(to: directory.appendingPathComponent("SURVIVOR-BOUND-TASK.json"))
            }
            await fixture.close()
        }
        #expect(Set(oldDigests).count == 1 && Set(newDigests).count == 3)
        if let output = ProcessInfo.processInfo.environment["IBRAIN_CURRENT_SCOPE_ARTIFACT_DIR"] {
            let file = URL(fileURLWithPath: output).appendingPathComponent("SCOPE-CONTRAST.json")
            try JSONSerialization.data(withJSONObject: ["scope": "Offline task contrast, not model outcomes", "cases": contrast, "modelCalls": 0], options: [.prettyPrinted, .sortedKeys]).write(to: file)
        }
    }

    @Test(arguments: ["documents", "occurrences"])
    func authoredNamedSubjectLookupReadsActualSurvivorDateTime(_ unit: String) async throws {
        let fixture = try await SurvivorFixture()
        let prepared = try await fixture.scopedTask()
        #expect(prepared.task.version == "photo-product-query-compact-v2.3-current-source-scope")
        let inventory = try ExhaustiveAppointmentPlanner.task(fixture.input, policy: .resultUnitsV4)
        let words = try #require(inventory.questions["start_0"]?.criteria)
        let start = try #require(words.first { $0.value == "lens" }?.key)
        let end = try #require(words.first { $0.value == "fitting" }?.key)
        let authored = try scopedReceipt(prepared, scopedInventory(["unit": unit, "documentKind": "appointment", "predicates": [["field": "title", "operator": "contains", "start": start, "end": end]], "requestedDetails": ["localDate", "startClock"]]))
        let decision = try CompactProductQueryPlanner.compile(authored, for: prepared)
        let owner = ExhaustiveAppointmentSession(store: fixture.store)
        let request = UUID()
        _ = try await owner.prepare(fixture.input, requestID: request, compactDecision: decision)
        let flat = try await owner.advance(activeRequestID: request)
        _ = try await owner.admit(flat, activeRequestID: request)
        #expect(flat.matches.count == 1 && flat.uncertain.isEmpty && flat.unresolvedDetails.isEmpty)
        let projection = try #require(flat.matches.first?.projection)
        #expect(projection.recordID == "pin.record.3228BA09-2409-4C70-8525-DBE25B3CDFB4")
        #expect(projection.sources == [fixture.originalSource.reference])
        let date = projection.appointment.date
        #expect(date.year == 2026 && date.month == 11 && date.day == 4 && date.hour == 15 && date.minute == 25)
        #expect(date.timeZoneID == "America/Los_Angeles" && flat.plan.requestedDetails == [.localDate, .startClock])
        #expect(flat.plan.receipt.compactProductQueryReceipt == authored)
        #expect(flat.plan.resultUnit?.rawValue == unit)
        if let output = ProcessInfo.processInfo.environment["IBRAIN_CURRENT_SCOPE_ARTIFACT_DIR"] {
            let file = URL(fileURLWithPath: output).appendingPathComponent("AUTHORED-SURVIVOR-" + unit + "-ANSWER.json")
            let summary: [String: Any] = ["scope": "Authored offline query decision over exact retained native survivor; no model accuracy claim", "resultUnit": unit, "recordID": projection.recordID, "sourceID": fixture.originalSource.reference.id, "sourceRevision": fixture.originalSource.reference.revision, "date": "2026-11-04", "startClock": "15:25", "timeZone": date.timeZoneID!, "requestedDetails": ["localDate", "startClock"], "matchedRecords": flat.matches.count, "uncertainRecords": flat.uncertain.count, "modelCalls": 0]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        }
        await fixture.close()
    }

    @Test(arguments: [(0, "clarify", "target"), (1, "clarify", "target"), (2, "clarify", "target"), (1, "unknown", "meaning"), (1, "unsupported", "unit")])
    func genuineNoExecutionChoicesRemainAvailable(_ count: Int, _ route: String, _ reason: String) async throws {
        let fixture = try await SurvivorFixture(sourceCount: count)
        let question = route == "unsupported" ? "Count the people in the remaining photo." : "Show the earlier second photo I selected."
        let prepared = try await fixture.scopedTask(question)
        let decision = try CompactProductQueryPlanner.compile(scopedReceipt(prepared, ["kind": route, "reason": reason]), for: prepared)
        #expect(decision.route.rawValue == route && decision.reason == reason)
        #expect(prepared.task.state.contains(question))
        await fixture.close()
    }

    @Test func currentSnapshotCannotManufactureDisplayedContextOrActions() async throws {
        let fixture = try await SurvivorFixture()
        let prepared = try await fixture.scopedTask()
        let bad: [[String: Any]] = [
            ["kind": "contextual", "operation": "details", "target": "unit_0", "requestedDetails": ["localDate"], "changeFields": "none", "evidenceFacets": []],
            scopedInventory(["target": "currentPhoto"]),
            scopedInventory(["sourceCount": 1]),
            scopedInventory(["unit": "photos"]),
            scopedInventory(["operation": "forget"]),
            scopedInventory(["requestedDetails": ["localDate", "localDate"]])
        ]
        for invalid in bad {
            #expect(throws: (any Error).self) { try CompactProductQueryPlanner.compile(scopedReceipt(prepared, invalid), for: prepared) }
        }
        await fixture.close()
    }

    @Test func opaquePermitRejectsCrossStoreAndForget() async throws {
        let fixture = try await SurvivorFixture()
        let other = try await SurvivorFixture()
        let prepared = try await fixture.scopedTask()
        let decision = try CompactProductQueryPlanner.compile(scopedReceipt(prepared, scopedInventory()), for: prepared)
        do {
            try await decision.validateCurrentAuthority(in: other.store)
            Issue.record("Another store accepted the source scope")
        } catch {}
        try await fixture.store.invalidateSource(id: fixture.originalSource.reference.id, forget: true)
        do {
            try await decision.validateCurrentAuthority(in: fixture.store)
            Issue.record("Forgotten source scope was accepted")
        } catch {}
        try await fixture.store.synchronize(.init(sources: [], records: []))
        let current = try await fixture.scopedTask()
        #expect(try current.task.digest() != prepared.task.digest())
        let state = try JSONSerialization.jsonObject(with: Data(current.task.state.utf8)) as! [String: Any]
        #expect((state["currentSourceScope"] as! [String: Any])["sourceCount"] as? Int == 0)
        await fixture.close()
        await other.close()
    }

    @Test func sameCountChangedSourceReferenceChangesBindingAndRevokesOldPermit() async throws {
        let fixture = try await SurvivorFixture()
        let before = try await fixture.scopedTask()
        let decision = try CompactProductQueryPlanner.compile(scopedReceipt(before, scopedInventory()), for: before)
        let source = fixture.originalSource
        let revised = SourceSnapshot(reference: .init(id: source.reference.id, revision: source.reference.revision + 1, fingerprint: "AUTHORED-new-current-fingerprint"), scope: source.scope, observations: source.observations)
        try await fixture.store.synchronize(.init(sources: [revised], records: []))
        let after = try await fixture.scopedTask()
        #expect(try after.task.digest() != before.task.digest())
        do {
            try await decision.validateCurrentAuthority(in: fixture.store)
            Issue.record("Changed current source retained old authority")
        } catch {}
        await fixture.close()
    }

    @Test func oneSourceStillAllowsMultipleBookingDocuments() async throws {
        let fixture = try await MemberContractFixture()
        let input = MemberContractFixture.input(nil, "List documents shown in the current photo.")
        let prepared = try CompactProductQueryPlanner.prepareCurrentSourceScope(taskID: "one-source-two-documents", inventory: ExhaustiveAppointmentPlanner.task(input, policy: .resultUnitsV4), sources: await fixture.store.sourceSearchSnapshot(permit: fixture.store.permit()))
        let state = try JSONSerialization.jsonObject(with: Data(prepared.task.state.utf8)) as! [String: Any]
        #expect((state["currentSourceScope"] as! [String: Any])["sourceCount"] as? Int == 1)
        let decision = try CompactProductQueryPlanner.compile(scopedReceipt(prepared, scopedInventory()), for: prepared)
        let owner = ExhaustiveAppointmentSession(store: fixture.store)
        let request = UUID()
        _ = try await owner.prepare(input, requestID: request, compactDecision: decision)
        let flat = try await owner.advance(activeRequestID: request)
        let native = try await owner.inventoryUnitAnswer(flat, prepared: fixture.preparedDocuments, activeRequestID: request)
        #expect(native.exactCount == 2 && native.orderedUnits.count == 2)
        await fixture.close()
    }

    @Test func explicitOccurrenceCountDateAndDetailsRemainSelected() async throws {
        let fixture = try await SurvivorFixture()
        let question = "Count scheduled appointment occurrences tomorrow in the current photo, with date, start time and explicit timezone."
        let input = EvidenceQuestionInput(taskID: fixture.input.taskID, question: question, now: fixture.input.now, calendar: fixture.input.calendar)
        let prepared = try await fixture.scopedTask(question)
        let output = scopedInventory(["operation": "count", "unit": "occurrences", "window": "tomorrow", "status": "scheduled", "documentKind": "appointment", "requestedDetails": ["localDate", "startClock", "explicitTimeZone"]])
        let receipt = try scopedReceipt(prepared, output)
        let decision = try CompactProductQueryPlanner.compile(receipt, for: prepared)
        let owner = ExhaustiveAppointmentSession(store: fixture.store)
        let request = UUID()
        _ = try await owner.prepare(input, requestID: request, compactDecision: decision)
        let flat = try await owner.advance(activeRequestID: request)
        #expect(flat.matches.isEmpty && flat.uncertain.isEmpty)
        #expect(flat.plan.operation == .count && flat.plan.resultUnit == .occurrences)
        #expect(flat.plan.requestedDetails == [.localDate, .startClock, .explicitTimeZone])
        #expect(flat.plan.receipt.compactProductQueryReceipt == receipt)
        await fixture.close()
    }
}

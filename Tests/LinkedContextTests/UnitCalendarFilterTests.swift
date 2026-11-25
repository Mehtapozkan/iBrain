import Foundation
import Testing
import IBrain
@testable import IBrainSemantics

private struct RetainedCalendarPreparation: Decodable {
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
    let questionRequestID: UUID
}

private struct CalendarSnapshot: Decodable {
    struct Row: Decodable { let projection: MemoryProjection }
    let scope: MemoryScope
    let rows: [String: Row]
}

private struct RetainedCalendarEnvelope: Decodable { let task: CompactProductQueryTask }
private struct RetainedCalendarResponse: Decodable { let receipt: CompactProductQueryReceipt }
private struct RetainedValueContext: Decodable {
    struct Context: Decodable { let source: SourceSnapshot }
    let context: Context
}

private struct CalendarReplay {
    let store: MemoryStore
    let directory: URL
    let input: EvidenceQuestionInput
    let requestID: UUID
    let session: ExhaustiveAppointmentSession
    let flat: ExhaustiveAppointmentAnswer
    let projections: [MemoryProjection]
    let preparedUnits: PreparedInventoryUnits

    init(_ name: String) async throws {
        let resource = try #require(Bundle.module.url(forResource: name + ".preparation", withExtension: "json", subdirectory: "Fixtures/CalendarFailure"))
        let folder = resource.deletingLastPathComponent()
        let decoder = JSONDecoder()
        let preparation = try decoder.decode(RetainedCalendarPreparation.self, from: Data(contentsOf: resource))
        let snapshot = try decoder.decode(CalendarSnapshot.self, from: preparation.authority.sdkMemory)
        projections = snapshot.rows.values.map(\.projection).sorted { $0.recordID < $1.recordID }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-replay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try preparation.authority.sdkMemory.write(to: directory.appendingPathComponent("memory.json"))
        store = try MemoryStore(directory: directory, scope: snapshot.scope)
        let sources = try preparation.authority.records.map {
            try decoder.decode(RetainedValueContext.self, from: $0.observation.sourceValueProof).context.source
        }
        let pins = projections.map { DomainRecordPin(id: $0.recordID, revision: $0.recordRevision, sources: $0.sources) }
        try await store.synchronize(.init(sources: sources, records: pins))
        var evidence: [InventorySourceUnitEvidence] = []
        for call in ["call-001", "call-004"] {
            let initialFolder = folder.appendingPathComponent("initial-source-proofs/" + call)
            let task = try decoder.decode(ChoiceTask.self, from: Data(contentsOf: initialFolder.appendingPathComponent("task.json")))
            let receipt = try decoder.decode(DecisionReceipt.self, from: Data(contentsOf: initialFolder.appendingPathComponent("receipt.json")))
            let state = try JSONSerialization.jsonObject(with: Data(task.state.utf8)) as! [String: Any]
            let original = state["sourceTask"] as! [String: Any]
            struct InitialState: Decodable { let source: SourceReference; let observations: [ObservedLine] }
            let initial = try decoder.decode(InitialState.self, from: Data((original["state"] as! String).utf8))
            let source = try #require(sources.first { $0.reference == initial.source })
            let projection = try #require(projections.first { $0.sources == [source.reference] })
            let request = ObservationRequest(taskID: original["id"] as! String, source: source, lines: initial.observations, declaredVisualClues: source.observations.filter { $0.kind == .visualLabel }.map(\.value), documentPolicy: .documentContentV4, temporalPolicy: .anchoredSpansV9)
            evidence.append(.single(.init(initialRequest: request, initialTask: task, initialReceipt: receipt, projection: projection)))
        }
        preparedUnits = try InventorySourceUnitCompiler.prepare(evidence, unit: .documents)
        #expect(!preparedUnits.identityResolved && preparedUnits.sourceReceipts.count == 2)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = 1
        calendar.minimumDaysInFirstWeek = 1
        input = .init(taskID: "pin-exhaustive-question", question: preparation.question, now: preparation.now, calendar: calendar)
        requestID = preparation.questionRequestID
        let original = try decoder.decode(RetainedCalendarEnvelope.self, from: Data(contentsOf: folder.appendingPathComponent(name + ".envelope.json"))).task
        let receipt = try decoder.decode(RetainedCalendarResponse.self, from: Data(contentsOf: folder.appendingPathComponent(name + ".response.json"))).receipt
        let prepared = try CompactProductQueryPlanner.prepare(taskID: original.id, inventory: ExhaustiveAppointmentPlanner.task(input, policy: .resultUnitsV4), contextual: nil, permit: await store.permit(), contract: .photoScopeInventoryV22)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        #expect(try encoder.encode(prepared.task) == encoder.encode(original))
        let decision = try CompactProductQueryPlanner.compile(receipt, for: prepared)
        session = ExhaustiveAppointmentSession(store: store)
        _ = try await session.prepare(input, requestID: requestID, compactDecision: decision)
        flat = try await session.advance(activeRequestID: requestID)
        _ = try await session.admit(flat, activeRequestID: requestID)
        #expect(flat.coverage.entireAdmittedInventory && flat.coverage.totalRecords == 2)
        #expect(flat.plan.receipt.compactProductQueryReceipt == receipt)
    }

    func units() -> [SourceOccurrenceUnit] {
        projections.map { .init(id: "DIAGNOSTIC-" + $0.recordID, members: [.init(groupOrdinal: 0, projection: $0)], conflictingFields: []) }
    }

    func close() async {
        await store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func authoredFlat(window: String, unit: String = "occurrences", details: [String] = []) async throws -> ExhaustiveAppointmentAnswer {
        let nativeInput = EvidenceQuestionInput(taskID: "authored-unit-neighbor", question: "List booking occurrences in this calendar interval with the requested details.", now: input.now, calendar: input.calendar)
        let prepared = try CompactProductQueryPlanner.prepare(taskID: "authored-unit-neighbor-parent", inventory: ExhaustiveAppointmentPlanner.task(nativeInput, policy: .resultUnitsV4), contextual: nil, permit: await store.permit(), contract: .photoScopeInventoryV22)
        let output: [String: Any] = ["decision": ["kind": "inventory", "operation": "list", "unit": unit, "window": window, "status": "all", "documentKind": "all", "clockBounds": [], "predicates": [], "requestedDetails": details, "evidenceFacets": []]]
        let bytes = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        let receipt = CompactProductQueryReceipt(provider: "AUTHORED-NEIGHBOR-NOT-MODEL", model: "NO-INFERENCE", requestSHA256: try prepared.task.digest(), outputJSON: String(decoding: bytes, as: UTF8.self), elapsedSeconds: 0)
        let decision = try CompactProductQueryPlanner.compile(receipt, for: prepared)
        let owner = ExhaustiveAppointmentSession(store: store)
        let request = UUID()
        _ = try await owner.prepare(nativeInput, requestID: request, compactDecision: decision)
        let answer = try await owner.advance(activeRequestID: request)
        return try await owner.admit(answer, activeRequestID: request)
    }
}

private struct UncertainTemporalFixture {
    let store: MemoryStore
    let directory: URL
    let projection: MemoryProjection
    let input: EvidenceQuestionInput

    init(_ variant: String) async throws {
        let scope = MemoryScope(ownerID: "AUTHORED-temporal-neighbor", namespace: variant)
        let reference = SourceReference(id: "AUTHORED-" + variant, revision: 1, fingerprint: "AUTHORED-NO-PIXELS")
        let dateTexts = variant == "missingYear" ? ["6 November"] : variant == "conflictingDate" ? ["6 November 2026", "7 November 2026"] : ["6 November 2026"]
        var observations = [SourceObservation(id: "title", value: "Authored appointment"), SourceObservation(id: "zone", value: "America/Los_Angeles")]
        observations += dateTexts.enumerated().map { .init(id: "date-\($0.offset)", value: $0.element) }
        if variant != "missingClock" { observations.append(.init(id: "clock", value: "15:25")) }
        let source = SourceSnapshot(reference: reference, scope: scope, observations: observations)
        let anchors = observations.map { EvidenceAnchor(source: reference, observationID: $0.id, quote: $0.value) }
        let title = anchors.first { $0.observationID == "title" }!
        let support: [FieldSupport] = [
            .init(field: .title, anchors: [title], extractorVersion: "AUTHORED-NO-INFERENCE"),
            .init(field: .kind, anchors: [title], extractorVersion: "AUTHORED-NO-INFERENCE"),
            .init(field: .status, anchors: [title], extractorVersion: "AUTHORED-NO-INFERENCE"),
            .init(field: .date, anchors: anchors.filter { $0.observationID != "title" }, extractorVersion: "AUTHORED-NO-INFERENCE")
        ]
        let conflicting = variant == "conflictingDate"
        let date: EventDate
        if conflicting {
            date = .init(year: nil, month: nil, day: nil, hour: nil, minute: nil, timeZoneID: nil, certainty: .conflicting)
        } else {
            date = .init(year: variant == "missingYear" ? nil : 2026, month: 11, day: 6, hour: variant == "missingClock" ? nil : 15, minute: variant == "missingClock" ? nil : 25, timeZoneID: "America/Los_Angeles", printedDateText: dateTexts[0], printedTimeText: variant == "missingClock" ? nil : "15:25")
        }
        projection = .init(recordID: "AUTHORED-record-" + variant, recordRevision: 1, scope: scope, appointment: .init(title: "Authored appointment", date: date, kind: .appointment, status: .scheduled), support: support)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("uncertain-temporal-" + UUID().uuidString)
        store = try MemoryStore(directory: directory, scope: scope)
        try await store.synchronize(.init(sources: [source], records: [.init(id: projection.recordID, revision: 1, sources: projection.sources)]))
        _ = try await store.upsert(projection, permit: store.permit())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = 1
        input = .init(taskID: "authored-uncertain-temporal", question: "List today's documents starting after 9 PM.", now: Date(timeIntervalSince1970: 1794033708), calendar: calendar)
    }

    func answer(clockCondition: Bool, details: [String] = []) async throws -> ExhaustiveAppointmentAnswer {
        let question = clockCondition ? "List today's documents starting after 9 PM." : details.isEmpty ? "List today's documents." : "List today's documents with their start times."
        let nativeInput = EvidenceQuestionInput(taskID: input.taskID, question: question, now: input.now, calendar: input.calendar)
        let inventory = try ExhaustiveAppointmentPlanner.task(nativeInput, policy: .resultUnitsV4)
        let prepared = try CompactProductQueryPlanner.prepare(taskID: "authored-uncertain-parent", inventory: inventory, contextual: nil, permit: await store.permit(), contract: .photoScopeInventoryV22)
        var clocks: [[String: String]] = []
        if clockCondition {
            let clock = try #require(inventory.questions["clock_0"]?.criteria.keys.first { $0.hasPrefix("after:") })
            clocks = [["comparison": "after", "slot": String(clock.split(separator: ":")[1])]]
        }
        let output: [String: Any] = ["decision": ["kind": "inventory", "operation": "list", "unit": "documents", "window": "today", "status": "all", "documentKind": "all", "clockBounds": clocks, "predicates": [], "requestedDetails": details, "evidenceFacets": []]]
        let bytes = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        let receipt = CompactProductQueryReceipt(provider: "AUTHORED-TEMPORAL-CONTROL", model: "NO-INFERENCE", requestSHA256: try prepared.task.digest(), outputJSON: String(decoding: bytes, as: UTF8.self), elapsedSeconds: 0)
        let decision = try CompactProductQueryPlanner.compile(receipt, for: prepared)
        let owner = ExhaustiveAppointmentSession(store: store)
        let request = UUID()
        _ = try await owner.prepare(nativeInput, requestID: request, compactDecision: decision)
        let flat = try await owner.advance(activeRequestID: request)
        return try await owner.admit(flat, activeRequestID: request)
    }

    func close() async {
        await store.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite struct UnitCalendarFilterTests {
    @Test(arguments: ["today", "week"])
    func inspectPreUnitMatchingWithActualReceipts(_ name: String) async throws {
        let replay = try await CalendarReplay(name)
        let evaluated = SourceUnitQueryProjection.evaluate(replay.flat, units: replay.units(), identityResolved: false)
        let before = ["matches": replay.flat.matches.map { $0.projection.recordID }, "uncertain": replay.flat.uncertain.map { $0.projection.recordID }]
        let after = ["matches": evaluated.matched.map(\.id), "uncertain": evaluated.uncertain.map(\.id), "excluded": evaluated.excluded.map(\.id)]
        if let location = ProcessInfo.processInfo.environment["IBRAIN_CALENDAR_DIAGNOSTIC_DIR"] {
            let directory = URL(fileURLWithPath: location)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let result: [String: Any] = ["case": name, "preUnit": before, "unitProjection": after, "recordCount": replay.flat.coverage.totalRecords, "inspected": replay.flat.coverage.inspectedRecords, "exactOriginalTaskAndReceipt": true, "projectionOrigin": "Unmodified supplied SDK memory snapshot", "modelCalls": 0]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent(name + ".json"))
        }
        #expect(replay.flat.uncertain.isEmpty)
        #expect(replay.flat.matches.count == (name == "today" ? 0 : 2))
        #expect(evaluated.excluded.count == (name == "today" ? 2 : 0))
        #expect(evaluated.uncertain.count == (name == "today" ? 0 : 2))
        let native = try await replay.session.inventoryUnitAnswer(replay.flat, prepared: replay.preparedUnits, activeRequestID: replay.requestID)
        #expect(native.orderedUnits.count == (name == "today" ? 0 : 2))
        #expect(!native.identityResolved && native.exactCount == nil && native.countLowerBound == 0)
        #expect(native.countUpperBound == (name == "today" ? 0 : 2))
        #expect(native.queryReceipt.compactProductQueryReceipt == replay.flat.plan.receipt.compactProductQueryReceipt)
        await replay.close()
    }

    @Test(arguments: [false, true])
    func partialMemberMatchesStayUncertain(_ identityResolved: Bool) async throws {
        let replay = try await CalendarReplay("today")
        let flat = try await replay.authoredFlat(window: "remainingThisWeek")
        #expect(flat.matches.count == 1 && flat.uncertain.isEmpty)
        let unit = SourceOccurrenceUnit(id: "AUTHORED-partial-unit", members: replay.projections.enumerated().map { .init(groupOrdinal: $0.offset, projection: $0.element) }, conflictingFields: [])
        let result = SourceUnitQueryProjection.evaluate(flat, units: [unit], identityResolved: identityResolved)
        #expect(result.uncertain.map(\.id) == [unit.id] && result.excluded.isEmpty && result.matched.isEmpty)
        await replay.close()
    }

    @Test(arguments: [false, true])
    func conditionConflictStaysUncertainEvenWhenFlatMembersAreOutside(_ identityResolved: Bool) async throws {
        let replay = try await CalendarReplay("today")
        let flat = try await replay.authoredFlat(window: "today")
        #expect(flat.matches.isEmpty && flat.uncertain.isEmpty && flat.plan.resultUnit == .occurrences)
        let unit = SourceOccurrenceUnit(id: "AUTHORED-date-conflict", members: replay.projections.enumerated().map { .init(groupOrdinal: $0.offset, projection: $0.element) }, conflictingFields: [.date])
        let result = SourceUnitQueryProjection.evaluate(flat, units: [unit], identityResolved: identityResolved)
        #expect(result.uncertain.map(\.id) == [unit.id] && result.excluded.isEmpty)
        await replay.close()
    }

    @Test func currentSourceBindingStillRejectsWithdrawal() async throws {
        let replay = try await CalendarReplay("today")
        try await replay.store.invalidateSource(id: replay.projections[0].sources.first!.id, forget: true)
        do {
            _ = try await replay.session.inventoryUnitAnswer(replay.flat, prepared: replay.preparedUnits, activeRequestID: replay.requestID)
            Issue.record("Withdrawn native authority was admitted")
        } catch {}
        await replay.close()
    }

    @Test(arguments: [("missingYear", false), ("missingYear", true), ("conflictingDate", false), ("conflictingDate", true), ("missingClock", false), ("missingClock", true)])
    func genuineTemporalUnknownsSurvive(_ variant: String, _ identityResolved: Bool) async throws {
        let fixture = try await UncertainTemporalFixture(variant)
        let flat = try await fixture.answer(clockCondition: variant == "missingClock")
        #expect(flat.matches.isEmpty && flat.uncertain.count == 1)
        let unit = SourceOccurrenceUnit(id: "AUTHORED-uncertain-unit", members: [.init(groupOrdinal: 0, projection: fixture.projection)], conflictingFields: [])
        let result = SourceUnitQueryProjection.evaluate(flat, units: [unit], identityResolved: identityResolved)
        #expect(result.uncertain.map(\.id) == [unit.id] && result.excluded.isEmpty)
        #expect(result.gaps[unit.id]?.contains(.date) == true)
        await fixture.close()
    }

    @Test(arguments: [false, true])
    func requestedDetailGapIsPreservedForIncludedMembers(_ identityResolved: Bool) async throws {
        let fixture = try await UncertainTemporalFixture("missingClock")
        let flat = try await fixture.answer(clockCondition: false, details: ["startClock"])
        #expect(flat.matches.count == 1 && flat.uncertain.isEmpty)
        let unit = SourceOccurrenceUnit(id: "AUTHORED-detail-gap", members: [.init(groupOrdinal: 0, projection: fixture.projection)], conflictingFields: [])
        let result = SourceUnitQueryProjection.evaluate(flat, units: [unit], identityResolved: identityResolved)
        #expect(result.excluded.isEmpty && result.gaps[unit.id] == [.date])
        #expect(identityResolved ? result.matched.count == 1 : result.uncertain.count == 1)
        await fixture.close()
    }

    @Test(arguments: ["today", "week"])
    func resolvedIdentityKeepsProvenMembership(_ name: String) async throws {
        let replay = try await CalendarReplay(name)
        let result = SourceUnitQueryProjection.evaluate(replay.flat, units: replay.units(), identityResolved: true)
        #expect(result.uncertain.isEmpty)
        #expect(result.matched.count == (name == "today" ? 0 : 2))
        #expect(result.excluded.count == (name == "today" ? 2 : 0))
        await replay.close()
    }

    @Test(arguments: ["status", "literal", "clock"])
    func otherProvenNonmatchConditionsAlsoExclude(_ condition: String) async throws {
        let replay = try await CalendarReplay("today")
        let questions = ["status": "List cancelled booking documents.", "literal": "List booking documents from Absent Provider.", "clock": "List booking documents starting before 12 PM."]
        let input = EvidenceQuestionInput(taskID: "generic-nonmatch", question: questions[condition]!, now: replay.input.now, calendar: replay.input.calendar)
        let task = try ExhaustiveAppointmentPlanner.task(input, policy: .resultUnitsV4)
        let prepared = try CompactProductQueryPlanner.prepare(taskID: "generic-nonmatch-parent", inventory: task, contextual: nil, permit: await replay.store.permit(), contract: .photoScopeInventoryV22)
        var clocks: [[String: String]] = []
        var predicates: [[String: String]] = []
        if condition == "clock" {
            let clock = try #require(task.questions["clock_0"]?.criteria.keys.first { $0.hasPrefix("before:") })
            clocks = [["comparison": "before", "slot": String(clock.split(separator: ":")[1])]]
        }
        if condition == "literal" {
            let words = try #require(task.questions["start_0"]?.criteria)
            predicates = [["field": "provider", "operator": "contains", "start": try #require(words.first { $0.value == "Absent" }?.key), "end": try #require(words.first { $0.value == "Provider" }?.key)]]
        }
        let output: [String: Any] = ["decision": ["kind": "inventory", "operation": "list", "unit": "documents", "window": "all", "status": condition == "status" ? "cancelled" : "all", "documentKind": "all", "clockBounds": clocks, "predicates": predicates, "requestedDetails": [], "evidenceFacets": []]]
        let bytes = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        let receipt = CompactProductQueryReceipt(provider: "AUTHORED-CONDITION-CONTROL", model: "NO-INFERENCE", requestSHA256: try prepared.task.digest(), outputJSON: String(decoding: bytes, as: UTF8.self), elapsedSeconds: 0)
        let decision = try CompactProductQueryPlanner.compile(receipt, for: prepared)
        let owner = ExhaustiveAppointmentSession(store: replay.store)
        let request = UUID()
        _ = try await owner.prepare(input, requestID: request, compactDecision: decision)
        let flat = try await owner.advance(activeRequestID: request)
        #expect(flat.matches.isEmpty && flat.uncertain.isEmpty)
        let result = SourceUnitQueryProjection.evaluate(flat, units: replay.units(), identityResolved: false)
        #expect(result.excluded.count == 2 && result.matched.isEmpty && result.uncertain.isEmpty)
        await replay.close()
    }

    @Test func excludedUnitsStillRequireAllCurrentMemberBindings() async throws {
        let replay = try await CalendarReplay("today")
        let original = replay.preparedUnits
        let first = original.units[0]
        let member = first.members[0]
        let current = member.projection
        let changed = MemoryProjection(recordID: current.recordID, recordRevision: current.recordRevision + 1, scope: current.scope, appointment: current.appointment, support: current.support)
        let altered = SourceOccurrenceUnit(id: first.id, members: [.init(groupOrdinal: member.groupOrdinal, projection: changed)], conflictingFields: first.conflictingFields)
        let source = original.sources[0]
        let wrongSource = SourceSnapshot(reference: .init(id: source.reference.id, revision: source.reference.revision, fingerprint: "AUTHORED-wrong-fingerprint"), scope: source.scope, observations: source.observations)
        let variants: [PreparedInventoryUnits] = [
            .init(resultUnit: original.resultUnit, sources: original.sources, units: [altered] + Array(original.units.dropFirst()), sourceReceipts: original.sourceReceipts, localRelationReceipts: original.localRelationReceipts, bindingSHA256: original.bindingSHA256, identityResolved: false),
            .init(resultUnit: original.resultUnit, sources: [wrongSource] + Array(original.sources.dropFirst()), units: original.units, sourceReceipts: original.sourceReceipts, localRelationReceipts: original.localRelationReceipts, bindingSHA256: original.bindingSHA256, identityResolved: false),
            .init(resultUnit: original.resultUnit, sources: original.sources, units: [first], sourceReceipts: original.sourceReceipts, localRelationReceipts: original.localRelationReceipts, bindingSHA256: original.bindingSHA256, identityResolved: false)
        ]
        for invalid in variants {
            do {
                _ = try await replay.session.inventoryUnitAnswer(replay.flat, prepared: invalid, activeRequestID: replay.requestID)
                Issue.record("Excluded units bypassed current-member/source/coverage checks")
            } catch {}
        }
        await replay.close()
    }
}

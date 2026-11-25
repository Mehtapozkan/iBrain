import Foundation
import Testing
import IBrain
import IBrainSemantics

struct DocumentIdentityControlProvider: DecisionProvider {
    var overrides: [String: String] = [:]
    func decide(_ task: ChoiceTask) async throws -> DecisionReceipt {
        var values = ["coverage": "supported", "operation": "list", "window": "all", "status": "all", "kind": "all", "unit": "documents"]
        for i in 0..<8 {
            values["clock_\(i)"] = "any"
            for key in ["field", "operator", "start", "end"] { values["\(key)_\(i)"] = "none" }
        }
        for d in RequestedAppointmentDetail.allCases { values["detail_" + d.rawValue] = "optional" }
        for f in RequestedSourceEvidence.allCases { values["evidence_" + f.rawValue] = "optional" }
        values.merge(overrides) { _, new in new }
        return .init(provider: "AUTHORED-OFFLINE-CONTROL", model: "NO-INFERENCE", requestSHA256: try task.digest(),
            answers: values.mapValues { .init(choice: $0) }, elapsedSeconds: 0)
    }
}

struct DocumentIdentityFixture {
    let directory: URL, store: MemoryStore, owner: ExhaustiveAppointmentSession, requestID: UUID
    let sources: [SourceSnapshot], projections: [MemoryProjection], prepared: PreparedInventoryUnits
    let raw: ExhaustiveAppointmentAnswer, answer: InventoryUnitQueryAnswer
    let input: EvidenceQuestionInput
    let evidence: [InventorySourceUnitEvidence]

    init(mode: String = "different", overrides: [String: String] = [:], requestID: UUID = UUID(), sourceCount: Int = 2) async throws {
        self.requestID = requestID
        let scope = MemoryScope(ownerID: "AUTHORED-document-list", namespace: "offline-no-pixels")
        var sources: [SourceSnapshot] = [], projections: [MemoryProjection] = [], evidence: [InventorySourceUnitEvidence] = []
        for i in 0..<sourceCount {
            let ref = SourceReference(id: "AUTHORED-source-\(i)", revision: 1, fingerprint: "AUTHORED-pixels-not-read-\(i)")
            let title = mode == "duplicate" || mode == "reschedule" ? "AUTHORED Same Subject" : "AUTHORED Subject \(i)"
            let day = i == 1 && (mode == "reschedule" || mode == "excluded" || mode == "empty") ? 8 : mode == "empty" ? 8 : 7
            let dateText = "2026-11-\(day)", clock = "17:40"
            let values = [("title", title), ("venue", "AUTHORED Hall"), ("date", dateText), ("clock", clock), ("address", "AUTHORED 31 Main Street")] + (mode == "missingZone" ? [] : [("zone", "UTC")])
            let observations = values.map { SourceObservation(id: $0.0, value: $0.1) }
            let assessment: SourceReadAssessment? = mode == "reading" ? nil : try .init(source: ref, coverage: .readable,
                reader: "AUTHORED-NOT-MODEL", receiptSHA256: String(repeating: "a", count: 64), observations: observations)
            let source = SourceSnapshot(reference: ref, scope: scope, observations: observations, readAssessment: assessment)
            func anchor(_ key: String) -> EvidenceAnchor { .init(source: ref, observationID: key, quote: values.first { $0.0 == key }!.1) }
            var support: [FieldSupport] = [
                .init(field: .title, anchors: [anchor("title")], extractorVersion: "AUTHORED"),
                .init(field: .date, anchors: [anchor("date"), anchor("clock")] + (mode == "missingZone" ? [] : [anchor("zone")]), extractorVersion: "AUTHORED"),
                .init(field: .venue, anchors: [anchor("venue")], extractorVersion: "AUTHORED"),
                .init(field: .venueAddress, anchors: [anchor("address")], extractorVersion: "AUTHORED"),
                .init(field: .kind, anchors: [anchor("title")], extractorVersion: "AUTHORED"),
                .init(field: .status, anchors: [anchor("date")], extractorVersion: "AUTHORED")]
            if mode == "missingAddress" && i == 1 { support.removeAll { $0.field == .venueAddress } }
            let projection = MemoryProjection(recordID: "AUTHORED-record-\(i)", recordRevision: 1, scope: scope,
                appointment: .init(title: title, venue: "AUTHORED Hall",
                    date: .init(year: mode == "unknownDate" && i == 1 ? nil : 2026, month: 11, day: day,
                        hour: mode == "missingClock" && i == 1 ? nil : 17, minute: mode == "missingClock" && i == 1 ? nil : 40,
                        timeZoneID: mode == "missingZone" ? nil : "UTC", printedDateText: dateText, printedTimeText: clock), kind: .appointment, status: .scheduled,
                    venueAddress: mode == "missingAddress" && i == 1 ? nil : "AUTHORED 31 Main Street"), support: support)
            let request = ObservationRequest(taskID: "AUTHORED-source-choice-\(i)", source: source,
                lines: values.map { .init(id: $0.0, text: $0.1, confidence: 0) }, declaredVisualClues: [],
                documentPolicy: .documentContentV4, temporalPolicy: .anchoredSpansV9)
            let task = try VisualObservationInterpreter.task(request, detailPolicy: .componentsV4)
            var choices = task.questions.mapValues { q in q.criteria["unknown"] != nil ? "unknown" : q.criteria["other"] != nil ? "other" : q.criteria["exclude"] != nil ? "exclude" : q.criteria.keys.sorted().first! }
            choices.merge(["document": "booking", "documentCount": "one", "title": "title", "venue": "venue", "rawDate": "date", "rawTime": "clock", "confirmation": "title", "kind": "appointment", "status": "scheduled", "eventTitle_title": "include"]) { _, new in new }
            for key in task.questions.keys where key.hasPrefix("temporal_") && task.questions[key]?.criteria["event"] != nil { choices[key] = "event" }
            let receipt = DecisionReceipt(provider: "AUTHORED-OFFLINE-CONTROL", model: "NO-INFERENCE", requestSHA256: try task.digest(),
                answers: choices.filter { task.questions[$0.key] != nil }.mapValues { .init(choice: $0) }, elapsedSeconds: 0)
            evidence.append(.single(.init(initialRequest: request, initialTask: task, initialReceipt: receipt, projection: projection)))
            sources.append(source); projections.append(projection)
        }
        let unit: AppointmentResultUnit = overrides["unit"] == "occurrences" ? .occurrences : .documents
        self.evidence = evidence
        prepared = try InventorySourceUnitCompiler.prepare(evidence, unit: unit)
        var records = projections.map { DomainRecordPin(id: $0.recordID, revision: $0.recordRevision, sources: $0.sources) }
        if mode == "unlinked" {
            sources.append(.init(reference: .init(id: "AUTHORED-unlinked", revision: 1, fingerprint: "AUTHORED-unlinked"), scope: scope, observations: []))
        }
        if mode == "unprojected" { records.append(.init(id: "AUTHORED-unprojected", revision: 1, sources: [sources[0].reference])) }
        self.sources = sources; self.projections = projections
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-list-control-" + UUID().uuidString)
        store = try MemoryStore(directory: directory, scope: scope)
        try await store.synchronize(.init(sources: sources, records: records,
            pendingSourcePreparations: mode == "pending" ? [sources[0].reference] : []))
        _ = try await store.upsertBatch(projections, permit: store.permit())
        owner = ExhaustiveAppointmentSession(store: store)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: .init(year: 2026, month: 11, day: 7, hour: 12))!
        self.input = EvidenceQuestionInput(taskID: "AUTHORED-list-question", question: "List the documents and requested details in these photos.", now: now, calendar: calendar)
        _ = try await owner.prepare(input, requestID: requestID, provider: DocumentIdentityControlProvider(overrides: overrides), planningPolicy: .resultUnitsV4)
        raw = try await owner.advance(activeRequestID: requestID)
        answer = try await owner.inventoryUnitAnswer(raw, prepared: prepared, activeRequestID: requestID)
    }

    func view() async throws -> SourceDocumentListAssessment { try await owner.sourceDocumentListAssessment(answer, activeRequestID: requestID) }
    func close() async { await store.close(); try? FileManager.default.removeItem(at: directory) }
}


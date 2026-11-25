import Foundation
import Testing
import IBrain
import IBrainSemantics

private struct ListControlProvider: DecisionProvider {
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

private struct DocumentListFixture {
    let directory: URL, store: MemoryStore, owner: ExhaustiveAppointmentSession, requestID: UUID
    let sources: [SourceSnapshot], projections: [MemoryProjection], prepared: PreparedInventoryUnits
    let raw: ExhaustiveAppointmentAnswer, answer: InventoryUnitQueryAnswer

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
        let input = EvidenceQuestionInput(taskID: "AUTHORED-list-question", question: "List the documents and requested details in these photos.", now: now, calendar: calendar)
        _ = try await owner.prepare(input, requestID: requestID, provider: ListControlProvider(overrides: overrides), planningPolicy: .resultUnitsV4)
        raw = try await owner.advance(activeRequestID: requestID)
        answer = try await owner.inventoryUnitAnswer(raw, prepared: prepared, activeRequestID: requestID)
    }

    func view() async throws -> SourceDocumentListAssessment { try await owner.sourceDocumentListAssessment(answer, activeRequestID: requestID) }
    func close() async { await store.close(); try? FileManager.default.removeItem(at: directory) }
}

private func mustReject(_ operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Unsupported/stale operation was admitted") } catch {}
}

private func proofBytes(_ receipt: DecisionReceipt) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(receipt)
}

@Suite struct SourceDocumentListAssessmentTests {
    @Test(arguments: ["different", "duplicate", "reschedule"])
    func supportedClaimsDoNotProveDistinctDocuments(_ mode: String) async throws {
        let f = try await DocumentListFixture(mode: mode), view = try await f.view()
        #expect(view.rows.count == 2 && view.rows.allSatisfy { $0.queryMembership == .matching })
        #expect(view.listedMembershipResolved && view.listedRequestedFieldsEstablished && view.requestedDetails.isEmpty)
        #expect(view.rows.map(\.unit.id) == f.answer.orderedUnits.map(\.id))
        #expect(view.rows.flatMap { $0.unit.members.map(\.projection) } == f.answer.orderedUnits.flatMap { $0.members.map(\.projection) })
        #expect(!view.identityResolved && view.countLowerBound == 0 && view.countUpperBound == 2 && view.exactCount == nil)
        #expect(!view.requestedAnswerComplete && f.answer.matchingUnits.isEmpty && f.answer.uncertainUnits.count == 2)
        #expect(view.evidenceBindingSHA256 == f.answer.evidenceBindingSHA256)
        #expect(try proofBytes(view.queryReceipt) == proofBytes(f.answer.queryReceipt))
        _ = try await f.owner.admitSourceDocumentListAssessment(view, activeRequestID: f.requestID)
        await f.close()
    }

    @Test(arguments: ["missingAddress", "missingClock", "missingZone"])
    func missingRequestedDetailsRemainExplicit(_ mode: String) async throws {
        let detail: RequestedAppointmentDetail = mode == "missingAddress" ? .venueAddress : mode == "missingClock" ? .startClock : .explicitTimeZone
        let f = try await DocumentListFixture(mode: mode, overrides: ["detail_" + detail.rawValue: "required"]), view = try await f.view()
        #expect(view.rows.allSatisfy { $0.queryMembership == .matching } && view.listedMembershipResolved)
        #expect(!view.listedRequestedFieldsEstablished && view.requestedDetails == [detail])
        #expect(view.rows.contains { $0.unresolvedDetails.contains(detail) && !$0.unresolvedFields.isEmpty })
        #expect(!view.requestedAnswerComplete)
        await f.close()
    }

    @Test(arguments: ["unknownDate", "excluded", "empty"])
    func nativeDateMembershipAndExclusionsStayIntact(_ mode: String) async throws {
        let f = try await DocumentListFixture(mode: mode, overrides: ["window": "today"]), view = try await f.view()
        if mode == "unknownDate" {
            #expect(view.rows.count == 2 && view.rows.contains { $0.queryMembership == .uncertain && $0.unresolvedDetails.contains(.localDate) })
            #expect(!view.listedMembershipResolved && !view.coverage.membershipComplete)
        } else {
            #expect(view.rows.count == (mode == "empty" ? 0 : 1))
            #expect(view.excludedRows.count == (mode == "empty" ? 2 : 1))
            #expect(view.excludedRows.allSatisfy { $0.queryMembership == .excluded })
            #expect(view.listedMembershipResolved && !view.requestedAnswerComplete && view.exactCount == nil)
        }
        await f.close()
    }

    @Test(arguments: ["reading", "pending", "unlinked", "unprojected"])
    func coverageWarningsAreSeparateFromMatchingClaims(_ mode: String) async throws {
        let f = try await DocumentListFixture(mode: mode), view = try await f.view()
        #expect(view.listedMembershipResolved && view.rows.allSatisfy { $0.queryMembership == .matching })
        #expect(!view.coverage.preparedSourceCoverageComplete && !view.requestedAnswerComplete)
        #expect(view.coverage.sourcesWithReadingGaps == f.answer.coverage.sourcesWithReadingGaps)
        #expect(view.coverage.pendingSourcePreparations == f.answer.coverage.pendingSourcePreparations)
        #expect(view.coverage.unlinkedSources == f.answer.coverage.unlinkedSources)
        #expect(view.coverage.unprojectedRecords == f.answer.coverage.unprojectedRecords)
        await f.close()
    }

    @Test(arguments: ["count", "occurrences", "sourceEvidence", "facetedList"])
    func unsupportedOperationsAndFacetsFailClosed(_ mode: String) async throws {
        let overrides: [String: String] = mode == "count" ? ["operation": "count"] : mode == "occurrences" ? ["unit": "occurrences"] : mode == "sourceEvidence" ? ["operation": "sourceEvidence", "evidence_documentedStatus": "required"] : ["evidence_currentPersonalBooking": "required"]
        let f = try await DocumentListFixture(overrides: overrides, sourceCount: 1)
        await mustReject { _ = try await f.view() }
        // Original answer is still admitted under its unchanged contract.
        _ = try await f.owner.admitInventoryUnitAnswer(f.answer, activeRequestID: f.requestID)
        await f.close()
    }

    @Test(arguments: ["wrongRequest", "foreignOwner", "revision", "fingerprint", "withdrawal", "forget"])
    func staleAndForeignAuthorityCannotPublishAssessmentOrContext(_ mode: String) async throws {
        let f = try await DocumentListFixture(), view = try await f.view()
        let owner = mode == "foreignOwner" ? ExhaustiveAppointmentSession(store: f.store) : f.owner
        let request = mode == "wrongRequest" ? UUID() : f.requestID
        if mode == "withdrawal" || mode == "forget" {
            try await f.store.invalidateSource(id: f.sources[0].reference.id, forget: mode == "forget")
        } else if mode == "revision" || mode == "fingerprint" {
            let s = f.sources[0], old = s.reference
            let changed = SourceSnapshot(reference: .init(id: old.id, revision: mode == "revision" ? 2 : old.revision,
                fingerprint: mode == "fingerprint" ? "AUTHORED-changed" : old.fingerprint), scope: s.scope, observations: s.observations)
            try await f.store.synchronize(.init(sources: [changed] + Array(f.sources.dropFirst()), records: []))
        }
        await mustReject { _ = try await owner.sourceDocumentListAssessment(f.answer, activeRequestID: request) }
        await mustReject { _ = try await owner.admitSourceDocumentListAssessment(view, activeRequestID: request) }
        await mustReject { _ = try await owner.contextForDisplayedSourceDocumentListAssessment(view, activeRequestID: request, displayedUnitIDs: view.rows.map(\.unit.id)) }
        await f.close()
    }

    @Test func displayedOrderAndOriginalBindingsMatchLegacyProof() async throws {
        let request = UUID(), display = UUID()
        let a = try await DocumentListFixture(requestID: request), b = try await DocumentListFixture(requestID: request)
        let view = try await a.view(), ids = Array(view.rows.map(\.unit.id).reversed())
        await mustReject { _ = try await a.owner.contextForDisplayedSourceDocumentListAssessment(view, activeRequestID: request, displayedUnitIDs: Array(ids.dropLast())) }
        await mustReject { _ = try await a.owner.contextForDisplayedSourceDocumentListAssessment(view, activeRequestID: request, displayedUnitIDs: [ids[0], ids[0]]) }
        let new = try await a.owner.contextForDisplayedSourceDocumentListAssessment(view, activeRequestID: request, displayedUnitIDs: ids, displayIdentity: display)
        let old = try await b.owner.contextForDisplayedInventoryUnitAnswer(b.answer, activeRequestID: request, displayedUnitIDs: ids, displayIdentity: display)
        #expect(new.bindingSHA256 == old.bindingSHA256 && new.orderedRows.map(\.unit.id) == ids)
        #expect(new.orderedRows.allSatisfy { $0.membershipUncertain && $0.memberSelection.values.allSatisfy { $0 == .matching } })
        let selection = try await a.owner.selectDisplayedUnit(new, ordinal: 1, activeAnswerRequestID: request)
        #expect(selection.row.unit.id == ids[0] && selection.currentSources == Set(view.rows.last!.unit.members[0].projection.sources))
        #expect(try proofBytes(selection.proof.queryReceipt) == proofBytes(a.answer.queryReceipt))
        try await a.store.invalidateSource(id: selection.currentSources.first!.id, forget: true)
        await mustReject { _ = try await a.owner.admitDisplayedUnitSelection(selection, activeAnswerRequestID: request) }
        await a.close(); await b.close()
    }

    @Test func existingSinglePhotoDocumentIdentityRemainsComplete() async throws {
        let f = try await DocumentListFixture(sourceCount: 1), view = try await f.view()
        #expect(view.identityResolved && view.exactCount == 1 && view.requestedAnswerComplete)
        #expect(view.requestedAnswerComplete == f.answer.requestedAnswerComplete && view.countLowerBound == f.answer.countLowerBound)
        await f.close()
    }

    @Test func onePhotoMultipleDocumentGroupsPreserveSourceLocalIdentityAndGaps() async throws {
        let f = try await MemberContractFixture(), owner = ExhaustiveAppointmentSession(store: f.store), request = UUID()
        _ = try await owner.prepare(MemberContractFixture.input(nil, "List the tickets and their addresses."), requestID: request,
            provider: ListControlProvider(overrides: ["detail_venueAddress": "required"]), planningPolicy: .resultUnitsV4)
        let raw = try await owner.advance(activeRequestID: request)
        let answer = try await owner.inventoryUnitAnswer(raw, prepared: f.preparedDocuments, activeRequestID: request)
        let view = try await owner.sourceDocumentListAssessment(answer, activeRequestID: request)
        #expect(view.rows.count == 2 && view.identityResolved && view.exactCount == 2)
        #expect(view.rows.allSatisfy { $0.queryMembership == .matching })
        #expect(view.rows.contains { $0.unit.members[0].projection.recordID == "z-ticket-first" && $0.unresolvedDetails == [.venueAddress] })
        #expect(!view.listedRequestedFieldsEstablished && !view.requestedAnswerComplete)
        await f.close()
    }

    @Test func incompleteInventoryCannotManufactureAssessment() async throws {
        let f = try await DocumentListFixture(), owner = ExhaustiveAppointmentSession(store: f.store), request = UUID()
        let raw = try await owner.prepare(MemberContractFixture.input(nil, "List the documents."), requestID: request,
            provider: ListControlProvider(), planningPolicy: .resultUnitsV4)
        #expect(!raw.coverage.entireAdmittedInventory)
        await mustReject { _ = try await owner.inventoryUnitAnswer(raw, prepared: f.prepared, activeRequestID: request) }
        await f.close()
    }
}

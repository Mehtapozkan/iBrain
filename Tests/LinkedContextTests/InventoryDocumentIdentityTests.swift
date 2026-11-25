import Foundation
import Testing
import IBrain
@testable import IBrainSemantics

private func docTask(_ f: DocumentIdentityFixture) throws -> ChoiceTask {
    try #require(try InventoryDocumentIdentityInterpreter.task(id: "AUTHORED-document-identity", prepared: f.prepared))
}
private func docReceipt(_ task: ChoiceTask, relation: String = "differentDocuments", overrides: [String: String] = [:]) throws -> DecisionReceipt {
    .init(provider: "AUTHORED-OFFLINE", model: "NO-INFERENCE", requestSHA256: try task.digest(),
        answers: task.questions.mapValues { _ in ChoiceAnswer(choice: relation) }.merging(overrides.mapValues { .init(choice: $0) }) { _, new in new }, elapsedSeconds: 0)
}
private func docAnswer(_ f: DocumentIdentityFixture, relation: String = "differentDocuments") async throws -> InventoryUnitQueryAnswer {
    let task = try docTask(f), receipt = try docReceipt(task, relation: relation)
    return try await f.owner.inventoryUnitAnswer(f.raw, prepared: f.prepared, relationTask: task, relationReceipt: receipt,
        documentIdentityPolicy: .crossSourceV1, activeRequestID: f.requestID)
}
private func docReject(_ operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Unsupported or stale document identity admitted") } catch {}
}
private func docCanonical<T: Encodable>(_ value: T) throws -> Data {
    let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try e.encode(value)
}

@Suite struct InventoryDocumentIdentityTests {
    @Test func oldDefaultStillHoldsAndOptInNeedsItsOwnReceipt() async throws {
        let f = try await DocumentIdentityFixture(), task = try docTask(f)
        #expect(!f.prepared.identityResolved && !f.answer.identityResolved && f.answer.exactCount == nil && !f.answer.requestedAnswerComplete)
        await docReject { _ = try await f.owner.inventoryUnitAnswer(f.raw, prepared: f.prepared, documentIdentityPolicy: .crossSourceV1, activeRequestID: f.requestID) }
        await docReject { _ = try await f.owner.inventoryUnitAnswer(f.raw, prepared: f.prepared, relationTask: task,
            relationReceipt: docReceipt(task), activeRequestID: f.requestID) }
        let url = try #require(Bundle.module.url(forResource: "default-control", withExtension: "json", subdirectory: "Fixtures/DocumentIdentityV48"))
        struct Snapshot: Encodable { let task: ChoiceTask; let binding: String; let units: [String]; let identity: Bool; let exact: Int?; let complete: Bool }
        let snapshot = Snapshot(task: try ExhaustiveAppointmentPlanner.task(f.input, policy: .resultUnitsV4), binding: f.prepared.bindingSHA256,
            units: f.prepared.units.map(\.id), identity: f.answer.identityResolved, exact: f.answer.exactCount, complete: f.answer.requestedAnswerComplete)
        #expect(try docCanonical(snapshot) == Data(contentsOf: url))
        await f.close()
    }
    @Test func differentDocumentsProduceCompleteAnswerAndExactContextWithoutEventCount() async throws {
        let f = try await DocumentIdentityFixture(), answer = try await docAnswer(f)
        #expect(answer.resultUnit == .documents && answer.identityResolved && answer.exactCount == 2 && answer.requestedAnswerComplete)
        #expect(answer.matchingUnits.count == 2 && answer.uncertainUnits.isEmpty && answer.crossSourceRelationReceipt != nil)
        #expect(try docCanonical(answer.queryReceipt) == docCanonical(f.raw.plan.receipt))
        #expect(answer.sourceReceipts.count == f.prepared.sourceReceipts.count)
        let ids = answer.orderedUnits.map(\.id).reversed().map { $0 }
        let context = try await f.owner.contextForDisplayedInventoryUnitAnswer(answer, activeRequestID: f.requestID, displayedUnitIDs: ids)
        #expect(context.resultUnit == .documents && context.identityResolved && context.orderedRows.count == 2)
        let selected = try await f.owner.selectDisplayedUnit(context, ordinal: 1, activeAnswerRequestID: f.requestID)
        #expect(selected.currentSources.count == 1 && selected.row.unit.id == ids[0])
        #expect(context.proof.crossSourceRelationReceipt?.requestSHA256 == answer.crossSourceRelationReceipt?.requestSHA256)
        await f.close()
    }
    @Test func duplicateCapturesMergeOnlyDocumentsAndRetainAllOwnSources() async throws {
        let f = try await DocumentIdentityFixture(mode: "duplicate"), answer = try await docAnswer(f, relation: "sameDocument")
        #expect(answer.exactCount == 1 && answer.requestedAnswerComplete && answer.matchingUnits[0].members.count == 2)
        #expect(Set(answer.matchingUnits[0].members.map { $0.projection.recordID }) == Set(f.projections.map(\.recordID)))
        let context = try await f.owner.contextForDisplayedInventoryUnitAnswer(answer, activeRequestID: f.requestID, displayedUnitIDs: answer.orderedUnits.map(\.id))
        let selection = try await f.owner.selectDisplayedUnit(context, ordinal: 1, activeAnswerRequestID: f.requestID)
        #expect(selection.currentSources == Set(f.sources.map(\.reference)))
        // The source-local one-member view cannot pretend this is a single claim.
        await docReject { _ = try await f.owner.sourceDocumentListAssessment(answer, activeRequestID: f.requestID) }
        await f.close()
    }
    @Test func distinctTicketsCanShareOneEventAndUnknownEventIdentityStaysUnknown() async throws {
        let f = try await DocumentIdentityFixture(mode: "duplicate"), docs = try await docAnswer(f)
        let prepared = try InventorySourceUnitCompiler.prepare(f.evidence, unit: .occurrences)
        let task = try #require(try InventoryOccurrenceInterpreter.task(id: "AUTHORED-event-relation", prepared: prepared))
        let same = try InventoryOccurrenceInterpreter.compile(id: task.id, prepared: prepared, task: task, receipt: docReceipt(task, relation: "sameOccurrence"))
        let unclear = try InventoryOccurrenceInterpreter.compile(id: task.id, prepared: prepared, task: task, receipt: docReceipt(task, relation: "unclear"))
        #expect(docs.exactCount == 2 && same.exactOccurrenceCount == 1 && unclear.exactOccurrenceCount == nil)
        #expect(throws: (any Error).self) { try InventoryDocumentIdentityInterpreter.compile(id: task.id, prepared: f.prepared, task: task, receipt: docReceipt(task, relation: "sameOccurrence")) }
        let eventOwner = ExhaustiveAppointmentSession(store: f.store), eventID = UUID()
        _ = try await eventOwner.prepare(f.input, requestID: eventID, provider: DocumentIdentityControlProvider(overrides: ["unit": "occurrences"]), planningPolicy: .resultUnitsV4)
        let eventRaw = try await eventOwner.advance(activeRequestID: eventID)
        let eventTask = try #require(try InventoryOccurrenceInterpreter.task(id: "AUTHORED-event-session", prepared: prepared))
        let eventReceipt = try docReceipt(eventTask, relation: "sameOccurrence")
        #expect(throws: (any Error).self) { try InventoryDocumentIdentityInterpreter.task(id: "AUTHORED-wrong-unit", prepared: prepared) }
        await docReject { _ = try await eventOwner.inventoryUnitAnswer(eventRaw, prepared: prepared, relationTask: eventTask,
            relationReceipt: eventReceipt, documentIdentityPolicy: .crossSourceV1, activeRequestID: eventID) }
        let eventAnswer = try await eventOwner.inventoryUnitAnswer(eventRaw, prepared: prepared, relationTask: eventTask,
            relationReceipt: eventReceipt, activeRequestID: eventID)
        #expect(eventAnswer.resultUnit == .occurrences && eventAnswer.exactCount == 1 && eventAnswer.requestedAnswerComplete)
        let documentTask = try docTask(f)
        await docReject { _ = try await eventOwner.inventoryUnitAnswer(eventRaw, prepared: prepared, relationTask: documentTask,
            relationReceipt: docReceipt(documentTask), activeRequestID: eventID) }
        await f.close()
    }
    @Test(arguments: ["different", "duplicate", "reschedule"])
    func uncertainDocumentRelationshipNeverBecomesExactFromNamesDatesOrIDs(_ mode: String) async throws {
        let f = try await DocumentIdentityFixture(mode: mode), answer = try await docAnswer(f, relation: "unclear")
        #expect(!answer.identityResolved && answer.exactCount == nil && !answer.requestedAnswerComplete && answer.uncertainUnits.count == 2)
        await f.close()
    }
    @Test(arguments: ["different", "reschedule"])
    func sameDocumentCannotMergeConflictingCurrentClaims(_ mode: String) async throws {
        let f = try await DocumentIdentityFixture(mode: mode)
        await docReject { _ = try await docAnswer(f, relation: "sameDocument") }
        await f.close()
    }
    @Test func missingRequestedFieldsAndCalendarRestrictionsRemainInTheAnswer() async throws {
        let f = try await DocumentIdentityFixture(mode: "missingAddress", overrides: ["detail_venueAddress": "required"])
        let answer = try await docAnswer(f)
        #expect(answer.identityResolved && answer.exactCount == 2 && !answer.requestedAnswerComplete)
        #expect(answer.unresolvedFieldsByUnit.values.contains { $0.contains(.venueAddress) })
        let today = try await DocumentIdentityFixture(mode: "excluded", overrides: ["window": "today"]), filtered = try await docAnswer(today)
        #expect(filtered.resultUnit == .documents && filtered.exactCount == 1 && filtered.excludedUnits.count == 1 && filtered.requestedAnswerComplete)
        let count = try await DocumentIdentityFixture(overrides: ["operation": "count"]), counted = try await docAnswer(count)
        #expect(counted.exactCount == 2 && counted.requestedAnswerComplete)
        await f.close(); await today.close(); await count.close()
    }
    @Test func lowConfidenceDocumentReceiptRemainsUnclear() async throws {
        let f = try await DocumentIdentityFixture(), task = try docTask(f)
        let receipt = DecisionReceipt(provider: "jev", model: "jev-1.13.0", requestSHA256: try task.digest(), answers: task.questions.mapValues { _ in
            ChoiceAnswer(choice: "differentDocuments", confidence: 0.7, probabilities: ["sameDocument": 0.1, "differentDocuments": 0.7, "unclear": 0.2]) }, elapsedSeconds: 0)
        let result = try InventoryDocumentIdentityInterpreter.compile(id: task.id, prepared: f.prepared, task: task, receipt: receipt)
        #expect(!result.identityResolved && result.exactDocumentCount == nil && result.receipt.provider == "jev")
        await f.close()
    }
    @Test(arguments: ["unclear", "differentDocuments"])
    func incompleteSameDocumentCliquesFailClosed(_ last: String) async throws {
        let f = try await DocumentIdentityFixture(mode: "duplicate", sourceCount: 3), task = try docTask(f)
        let receipt = try docReceipt(task, relation: "sameDocument", overrides: ["pair_1_2": last])
        #expect(throws: (any Error).self) { try InventoryDocumentIdentityInterpreter.compile(id: task.id, prepared: f.prepared, task: task, receipt: receipt) }
        await f.close()
    }
    @Test func sourceLocalDistinctDocumentsCannotCollapseThroughAnotherPhoto() async throws {
        let f = try await MemberContractFixture(), base = f.preparedDocuments, original = base.units[0].members[0].projection, old = base.sources[0]
        let ref = SourceReference(id: "AUTHORED-copy-photo", revision: 1, fingerprint: "AUTHORED-copy")
        let observations = old.observations
        let source = SourceSnapshot(reference: ref, scope: old.scope, observations: observations)
        let support = original.support.map { s in FieldSupport(field: s.field, origin: s.origin,
            anchors: s.anchors.map { .init(source: ref, observationID: $0.observationID, quote: $0.quote) }, extractorVersion: s.extractorVersion) }
        let copy = MemoryProjection(recordID: "AUTHORED-copy-record", recordRevision: 1, scope: original.scope, appointment: original.appointment, support: support)
        // Explicitly authored compiler topology: 2 already-distinct local docs +
        // a third capture. This is a graph guard, not fabricated source admission.
        let topology = PreparedInventoryUnits(resultUnit: .documents, sources: base.sources + [source],
            units: base.units + [SourceOccurrenceUnit(id: "AUTHORED-copy-unit", members: [.init(groupOrdinal: 0, projection: copy)], conflictingFields: [])],
            sourceReceipts: base.sourceReceipts, localRelationReceipts: [], bindingSHA256: String(repeating: "a", count: 64), identityResolved: false)
        let task = try #require(try InventoryDocumentIdentityInterpreter.task(id: "AUTHORED-local-partition", prepared: topology))
        #expect(task.questions.count == 2)
        #expect(throws: (any Error).self) { try InventoryDocumentIdentityInterpreter.compile(id: task.id, prepared: topology, task: task, receipt: docReceipt(task, relation: "sameDocument")) }
        await f.close()
    }
    @Test func receiptBindingCapacityAndSinglePhotoDefaultsStayStrict() async throws {
        let f = try await DocumentIdentityFixture(), task = try docTask(f), changed = try await DocumentIdentityFixture(mode: "reschedule")
        #expect(throws: (any Error).self) { try InventoryDocumentIdentityInterpreter.compile(id: task.id, prepared: changed.prepared, task: task, receipt: docReceipt(task)) }
        let wrong = ChoiceTask(id: task.id, state: task.state + " ", questions: task.questions, version: task.version)
        #expect(throws: (any Error).self) { try InventoryDocumentIdentityInterpreter.compile(id: task.id, prepared: f.prepared, task: wrong, receipt: docReceipt(wrong)) }
        let single = try await DocumentIdentityFixture(sourceCount: 1)
        #expect(try InventoryDocumentIdentityInterpreter.task(id: "AUTHORED-single", prepared: single.prepared) == nil)
        let answer = try await single.owner.inventoryUnitAnswer(single.raw, prepared: single.prepared, documentIdentityPolicy: .crossSourceV1, activeRequestID: single.requestID)
        #expect(answer.exactCount == 1 && answer.requestedAnswerComplete)
        let many = try await DocumentIdentityFixture(sourceCount: 65)
        #expect(throws: (any Error).self) { try InventoryDocumentIdentityInterpreter.task(id: "AUTHORED-65", prepared: many.prepared) }
        await f.close(); await changed.close(); await single.close(); await many.close()
    }
    @Test(arguments: ["withdrawal", "forget", "revision", "fingerprint", "wrongRequest", "foreignOwner"])
    func existingCurrentAuthorityAndPublicationFencesRemain(_ mode: String) async throws {
        let f = try await DocumentIdentityFixture(), answer = try await docAnswer(f), task = try docTask(f)
        let owner = mode == "foreignOwner" ? ExhaustiveAppointmentSession(store: f.store) : f.owner
        let request = mode == "wrongRequest" ? UUID() : f.requestID
        if mode == "withdrawal" || mode == "forget" { try await f.store.invalidateSource(id: f.sources[0].reference.id, forget: mode == "forget") }
        if mode == "revision" || mode == "fingerprint" {
            let s = f.sources[0], ref = s.reference
            let next = SourceSnapshot(reference: .init(id: ref.id, revision: mode == "revision" ? 2 : ref.revision, fingerprint: mode == "fingerprint" ? "AUTHORED-changed" : ref.fingerprint), scope: s.scope, observations: s.observations)
            try await f.store.synchronize(.init(sources: [next] + Array(f.sources.dropFirst()), records: []))
        }
        await docReject { _ = try await owner.inventoryUnitAnswer(f.raw, prepared: f.prepared, relationTask: task, relationReceipt: docReceipt(task), documentIdentityPolicy: .crossSourceV1, activeRequestID: request) }
        await docReject { _ = try await owner.admitInventoryUnitAnswer(answer, activeRequestID: request) }
        await docReject { _ = try await owner.contextForDisplayedInventoryUnitAnswer(answer, activeRequestID: request, displayedUnitIDs: answer.orderedUnits.map(\.id)) }
        await f.close()
    }
}

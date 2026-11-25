import Foundation
import IBrain
import IBrainSemantics
import Testing

@Suite struct SourceLifecycleAuditTests {
    // The image bytes and domain pin can remain identical when native OCR is corrected.
    @Test func correctedObservationWithdrawsItsAppointmentAndWorldRelationshipsAcrossReopen() async throws {
        let fixture = try Fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try await fixture.install(directory: directory)
        let id = UUID()
        let oldAnswer = try await original.queryWorldCurrent(.init(kind: .event, requested: [.locatedAt]), requestID: id)
        let sources = fixture.sources.map { source in
            guard source.reference.id == "photo-update" else { return source }
            return SourceSnapshot(reference: source.reference, scope: source.scope, observations: source.observations.map {
                $0.id == "venue" ? SourceObservation(id: $0.id, value: "West Room") : $0
            })
        }
        let authority = AuthoritySnapshot(sources: sources, records: fixture.authority.records)
        func checkCurrent(_ store: MemoryStore) async throws {
            let permit = try await store.synchronize(authority)
            let records = try await store.recordSearchSnapshot(permit: permit)
            #expect(records.records.map { $0.projection.recordID } == [fixture.other.recordID])
            #expect(try await store.recordInventory(permit: permit).unprojectedRecordIDs.contains(fixture.current.recordID))
            #expect(try await store.sourceChangeSnapshot(permit: permit).isEmpty)
            let world = try await store.queryWorldCurrent(.init(kind: .place, requested: [.name]), requestID: UUID())
            #expect(world.matches.allSatisfy { $0.recordID != "world-studio" })
            await #expect(throws: MemoryError.staleResult) {
                _ = try await store.resolveWorldAnswer(oldAnswer, activeRequestID: id)
            }
        }
        try await checkCurrent(original)
        await original.close()
        let reopened = try MemoryStore(directory: directory, scope: fixture.scope)
        try await checkCurrent(reopened)
        await reopened.close()
    }

    @Test func sameWordsWithChangedObservationKindRevokeVisualAndTranscriptionClaims() async throws {
        let scope = MemoryScope(ownerID: "fictional", namespace: "modality")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory, scope: scope)
        let ref = SourceReference(id: "programme", revision: 1, fingerprint: "programme-image")
        let target = SourceReference(id: "performer", revision: 1, fingerprint: "performer-image")
        let targetSource = SourceSnapshot(reference: target, scope: scope, observations: [.init(id: "name", value: "Alba")])
        let source = SourceSnapshot(reference: ref, scope: scope, observations: [
            .init(id: "caption", value: "Alba"), .init(id: "figure", kind: .visualLabel, value: "portrait")
        ])
        let document = try WorldObservationCompiler.document(source: source, recordID: "programme", recordRevision: 1, extractorVersion: "test")
        let edge = WorldMemoryProjection(recordID: "portrait", recordRevision: 1, scope: scope, kind: .object, claims: [
            .init(id: "depiction", predicate: .depicts, value: .entity("alba"),
                  anchors: document.claims.flatMap(\.anchors), extractorVersion: "test")
        ])
        let person = WorldMemoryProjection(recordID: "alba", recordRevision: 1, scope: scope, kind: .person, claims: [
            .init(id: "name", predicate: .name, value: .text("Alba"), anchors: [.init(source: target, observationID: "name", quote: "Alba")],
                  extractorVersion: "test")
        ])
        let rows = [document, edge, person]
        let pins = rows.map { DomainRecordPin(id: $0.recordID, revision: 1, sources: $0.sources, recordKind: .worldEntity) }
        let permit = try await store.synchronize(.init(sources: [source, targetSource], records: pins))
        _ = try await store.applyWorldBatch(rows.map { WorldMemoryWrite($0) }, permit: permit)
        let newRead = SourceSnapshot(reference: ref, scope: scope, observations: [
            .init(id: "caption", value: "Alba"), .init(id: "figure", value: "portrait")
        ])
        let revised = try await store.synchronize(.init(sources: [newRead, targetSource], records: pins))
        let actual = try await store.worldSearchSnapshot(permit: revised).entities.map { $0.projection.recordID }
        #expect(actual == ["alba"])

        // A newly added visual label with the same string cannot continue to serve as printed text.
        let textSource = SourceSnapshot(reference: ref, scope: scope, observations: [.init(id: "caption", value: "Alba")])
        let transcription = try WorldObservationCompiler.document(source: textSource, recordID: "caption", recordRevision: 1, extractorVersion: "test")
        let captionPin = DomainRecordPin(id: "caption", revision: 1, sources: [ref], recordKind: .worldEntity)
        let textPermit = try await store.synchronize(.init(sources: [textSource, targetSource], records: [captionPin] + pins.filter { $0.id == "alba" }))
        _ = try await store.applyWorldBatch([WorldMemoryWrite(transcription)], permit: textPermit)
        let reclassified = SourceSnapshot(reference: ref, scope: scope, observations: [.init(id: "caption", kind: .visualLabel, value: "Alba")])
        let visualPermit = try await store.synchronize(.init(sources: [reclassified, targetSource], records: [captionPin] + pins.filter { $0.id == "alba" }))
        #expect(try await store.worldSearchSnapshot(permit: visualPermit).entities.map { $0.projection.recordID } == ["alba"])
        await store.close()
    }

    @Test func disputedHistoricalStartCannotSupplyTheBeforeValueAfterReread() async throws {
        let fixture = try Fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await fixture.install(directory: directory)
        #expect(try await store.sourceChangeSnapshot(permit: store.permit()).count == 1)
        let sources = fixture.sources.map { source in
            guard source.reference.id == "photo-old" else { return source }
            return SourceSnapshot(reference: source.reference, scope: source.scope, observations: source.observations,
                                  readAssessment: source.readAssessment, printedStartReadConflict: true)
        }
        let authority = AuthoritySnapshot(sources: sources, records: fixture.authority.records)
        let permit = try await store.synchronize(authority)
        #expect(try await store.sourceChangeSnapshot(permit: permit).isEmpty)
        #expect(try await store.recordSearchSnapshot(permit: permit, recordIDs: [fixture.current.recordID]).records.first?.projection == fixture.current)
        await store.close()
        let reopened = try MemoryStore(directory: directory, scope: fixture.scope)
        let restored = try await reopened.synchronize(authority)
        #expect(try await reopened.sourceChangeSnapshot(permit: restored).isEmpty)
        await reopened.close()
    }
}

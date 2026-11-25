import Foundation
import IBrain
import Testing

@Suite struct WorldSourceBoundaryTests {
    @Test func dateFieldsKeepDuplicateEvidenceAndPreserveTemporalUncertainty() async throws {
        let scope = MemoryScope(ownerID: "authored", namespace: "world-dates")
        let reference = SourceReference(id: "photo", revision: 1, fingerprint: "date-authority")
        let source = SourceSnapshot(reference: reference, scope: scope, observations: [
            .init(id: "line", value: "Retained fixture date"), .init(id: "second", value: "Second retained date excerpt")
        ])
        let explicit = EventDate(year: 2026, month: 3, day: 3, hour: 20, minute: 0, timeZoneID: "UTC")
        let noZone = EventDate(year: 2026, month: 3, day: 3, hour: 20, minute: 0, timeZoneID: nil)
        let noYear = EventDate(year: nil, month: 3, day: 3, hour: 20, minute: 0, timeZoneID: "UTC")
        let overlap = EventDate(year: 2026, month: 11, day: 1, hour: 1, minute: 30, timeZoneID: "America/Los_Angeles")
        let other = EventDate(year: 2026, month: 3, day: 4, hour: 20, minute: 0, timeZoneID: "UTC")
        let inferred = EventDate(year: 2026, month: 3, day: 3, hour: 20, minute: 0, timeZoneID: "UTC", certainty: .inferred)
        let cases: [(String, [EventDate], FactOrigin, WorldFieldState)] = [
            ("known", [explicit, explicit], .observed, .known), ("zone", [noZone], .observed, .partial),
            ("year", [noYear], .observed, .partial), ("overlap", [overlap], .observed, .partial),
            ("alternatives", [explicit, other], .observed, .conflicting), ("inferred", [inferred], .inferred, .inferredOnly)
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try MemoryStore(directory: directory, scope: scope)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projections = cases.map { id, dates, origin, _ in
            WorldMemoryProjection(recordID: id, recordRevision: 1, scope: scope, kind: .event,
                claims: dates.enumerated().map { index, date in
                    let observation = source.observations[index]
                    return .init(id: "clock-\(index)", predicate: .scheduledAt, value: .date(date), origin: origin,
                        anchors: [.init(source: reference, observationID: observation.id, quote: observation.value)],
                        extractorVersion: "authored")
                })
        }
        let permit = try await store.synchronize(.init(sources: [source], records: projections.map {
            .init(id: $0.recordID, revision: 1, sources: [reference], recordKind: .worldEntity)
        }))
        _ = try await store.applyWorldBatch(projections.map { .init($0) }, permit: permit)
        let result = try await store.queryWorldCurrent(.init(kind: .event, requested: [.scheduledAt]), requestID: UUID())
        for (id, dates, origin, state) in cases {
            let field = try #require(result.matches.first { $0.recordID == id }?.fields.first)
            #expect(field.state == state)
            #expect(field.claims.map(\.value) == dates.map(WorldValue.date))
            #expect(field.claims.allSatisfy { $0.origin == origin })
        }
        await store.close()
    }

    @Test func relatedDetailsAndDisplayedFollowupsKeepTheExactSelectedSourceScope() async throws {
        let fixture = try Fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try await fixture.install(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = try #require(fixture.world.first { $0.recordID == "world-event-A" })
        let place = try #require(fixture.world.first { $0.recordID == "world-studio" })
        let query = WorldMemoryQuery(kind: .event, requested: [.name, .locatedAt])

        for (selected, venueAvailable) in [(event.sources, false), (event.sources.union(place.sources), true)] {
            let id = UUID()
            let answer = try await store.queryWorld(query, requestID: id, permit: store.permit(), sourceScope: selected)
            let parent = try #require(answer.matches.first)
            let parentState = try #require(parent.fields.last).state
            #expect(parentState == (venueAvailable ? .known : .unavailableTarget))
            let resolved = try await store.resolveWorldAnswer(answer, activeRequestID: id)
            #expect(resolved.relatedEntities.map(\.recordID) == (venueAvailable ? ["world-studio"] : []))
            #expect(resolved.relatedEntities.allSatisfy { $0.sources.isSubset(of: selected) })
            let context = try await store.bindWorldDisplayed(answer, orderedRecordIDs: [parent.recordID], activeRequestID: id)
            let detail = try await store.worldDetail(ordinal: 1, requested: [.locatedAt], context: context, activeAnswerID: id)
            #expect(detail.fields.first?.state == parentState)
            #expect(detail.sources.isSubset(of: selected))
        }

        let id = UUID()
        let unscoped = try await store.queryWorldCurrent(query, requestID: id)
        let resolved = try await store.resolveWorldAnswer(unscoped, activeRequestID: id)
        #expect(resolved.relatedEntities.contains { $0.recordID == "world-studio" })
        let context = try await store.bindWorldDisplayed(unscoped, orderedRecordIDs: [event.recordID], activeRequestID: id)
        try await store.invalidateSource(id: "photo-venue", forget: true)
        await #expect(throws: MemoryError.staleResult) {
            _ = try await store.resolveWorldAnswer(unscoped, activeRequestID: id)
        }
        await #expect(throws: MemoryError.staleResult) {
            _ = try await store.worldDetail(ordinal: 1, requested: [.locatedAt], context: context, activeAnswerID: id)
        }
        await store.close()
    }

    @Test func oneKnownRelationshipCanSettleExistenceButMissingTargetsCannotSettleAbsence() async throws {
        let scope = MemoryScope(ownerID: "authored-scope", namespace: "world-query")
        func source(_ id: String, _ text: String) -> SourceSnapshot {
            .init(reference: .init(id: id, revision: 1, fingerprint: "fixture-\(id)"), scope: scope,
                  observations: [.init(id: "line", value: text)])
        }
        func claim(_ id: String, _ predicate: WorldPredicate, _ value: WorldValue, _ source: SourceSnapshot) -> WorldClaim {
            .init(id: id, predicate: predicate, value: value,
                  anchors: [.init(source: source.reference, observationID: "line", quote: source.observations[0].value)],
                  extractorVersion: "authored-v1")
        }
        func row(_ id: String, _ kind: WorldEntityKind, _ claims: [WorldClaim]) -> WorldMemoryProjection {
            .init(recordID: id, recordRevision: 1, scope: scope, kind: kind, claims: claims)
        }

        let event = source("event", "Harbor Quartet performs with Vale Duo and Linden Trio")
        let vale = source("vale", "Vale Duo")
        let linden = source("linden", "Linden Trio")
        let rows = [
            row("concert", .event, [claim("known", .performedBy, .entity("vale"), event),
                                    claim("unavailable", .performedBy, .entity("linden"), event)]),
            row("vale", .person, [claim("name", .name, .text("Vale Duo"), vale)]),
            row("linden", .person, [claim("name", .name, .text("Linden Trio"), linden)])
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try MemoryStore(directory: directory, scope: scope)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = [event, vale, linden]
        let permit = try await store.synchronize(.init(sources: sources, records: rows.map {
            .init(id: $0.recordID, revision: $0.recordRevision, sources: $0.sources, recordKind: .worldEntity)
        }))
        _ = try await store.applyWorldBatch(rows.map { WorldMemoryWrite($0) }, permit: permit)
        let scoped = Set([event.reference, vale.reference])
        for (name, excluding, matches, unresolved) in [
            ("Vale Duo", false, true, false), ("Vale Duo", true, false, false),
            ("Linden Trio", false, false, true), ("Linden Trio", true, false, true),
            ("Other Group", true, false, true)
        ] {
            let query = WorldMemoryQuery(kind: .event,
                constraints: [.init(path: [.performedBy], predicate: .name, value: .text(name), excluding: excluding)],
                requested: [.performedBy])
            let id = UUID()
            let answer = try await store.queryWorld(query, requestID: id, permit: store.permit(), sourceScope: scoped)
            #expect(!answer.matches.isEmpty == matches)
            #expect(!answer.unresolved.isEmpty == unresolved)
            if let parent = answer.matches.first ?? answer.unresolved.first {
                #expect(parent.fields.first?.state == .unavailableTarget)
                #expect(parent.sources.isSubset(of: scoped))
            }
        }
        await store.close()
    }
}

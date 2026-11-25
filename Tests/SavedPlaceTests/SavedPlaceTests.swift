import Foundation
import IBrain
import IBrainRetrieval
import Testing

private let scope = MemoryScope(ownerID: "fictional", namespace: "test")
private let coverage = SavedPlaceCoverage(pendingSourceCount: 0, unresolvedSourceCount: 0)

private struct SourceFixture {
    let source: SourceSnapshot
    let row: SavedPlaceMention
    var pin: DomainRecordPin {
        .init(id: row.recordID, revision: row.recordRevision, sources: [row.source], recordKind: .worldEntity)
    }

    init(_ id: String, _ name: String, city: String = "Tokyo", neighborhood: String? = nil,
         branch: String? = nil, address: String? = nil, reason: String? = nil,
         role: SavedPlaceRole = .recommendation, revision: Int = 1,
         correction: (SavedPlaceField, String)? = nil) {
        let reference = SourceReference(id: id, revision: 1, fingerprint: "pixels-\(id)")
        var fields: [(SavedPlaceField, String)] = [(.name, name), (.city, city), (.category, "restaurant"),
                                                   (.subjectRole, role.rawValue)]
        let details: [(SavedPlaceField, String?)] = [
            (.neighborhood, neighborhood), (.branch, branch), (.address, address), (.reason, reason)
        ]
        fields += details.compactMap { field, val in val.map { (field, $0) } }
        let observations = fields.enumerated().map { index, field in
            SourceObservation(id: String(index), value: field.1)
        }
        var facts = fields.enumerated().map { index, field in
            SavedPlaceFact(field.0, value: field.1,
                           anchors: [.init(source: reference, observationID: String(index), quote: field.1)],
                           extractorVersion: "authored")
        }
        if let correction {
            facts.removeAll { $0.field == correction.0 }
            facts.append(.init(correction.0, value: correction.1, origin: .domainCorrection,
                               anchors: [], extractorVersion: "native-confirmed"))
        }
        source = SourceSnapshot(reference: reference, scope: scope, observations: observations)
        row = SavedPlaceMention(recordID: id, recordRevision: revision, source: reference, facts: facts)
    }
}

private func fixture() -> [SourceFixture] {
    [
        .init("A", "Ume Table", neighborhood: "Shibuya", reason: "Good for counter seating"),
        .init("B", "Ume Table", neighborhood: "Shibuya", branch: "Shibuya",
              address: "2-8 Example-dori", role: .listing),
        .init("C", "Ume Table", neighborhood: "Taito", branch: "Ueno"),
        .init("D", "Sora Noodles", reason: "Excellent soba"),
        .init("E", "Nearby map label", neighborhood: "Shibuya", role: .incidental),
        .init("F", "Sora Noodles", city: "Yokohama")
    ]
}

private func catalog(_ rows: [SourceFixture]) throws -> SavedPlaceCatalog {
    try .init(scope: scope, authority: .init(sources: rows.map(\.source), records: rows.map(\.pin)),
              mentions: rows.map(\.row), coverage: coverage)
}

@Test func tokyoAndContextualShibuya() throws {
    let rows = fixture()
    let current = try catalog(rows)
    let answer = try current.restaurants(in: "Tokyo", requestID: UUID())
    #expect(answer.cards.map(\.id) == ["A", "C", "D"])
    #expect(answer.unresolved.isEmpty)
    let shibuya = try #require(answer.cards.first)
    #expect(shibuya.members.map(\.recordID) == ["A", "B"])
    #expect(shibuya.evidence(for: .reason).flatMap(\.anchors).map(\.source.id) == ["A"])
    #expect(shibuya.evidence(for: .address).flatMap(\.anchors).map(\.source.id) == ["B"])
    let context = try current.displayedContext(for: answer, orderedCardIDs: ["D", "A", "C"])
    #expect(context.orderedCardIDs == ["D", "A", "C"])
    let newer = try catalog(rows + [.init("G", "New place", neighborhood: "Shibuya")])
    let refinement = try newer.refine(context, parentRequestID: answer.requestID, neighborhood: "Shibuya",
                                     requestID: UUID())
    #expect(refinement.cards.map(\.id) == ["A"])
    #expect(refinement.unresolved.map(\.id) == ["D"])
    let originals = try newer.originals(for: "A", in: context, parentRequestID: answer.requestID)
    #expect(originals.map(\.id) == ["A", "B"])
    let visits = try newer.visits(in: context, parentRequestID: answer.requestID, requestID: UUID())
    #expect(visits.cards.isEmpty)
    #expect(visits.unresolved.map(\.id) == ["D", "A", "C"])
}

@Test func confirmedCorrectionAndForgetRebuildFromAuthoritativeRecords() throws {
    let rows = fixture()
    let current = try catalog(rows)
    let initial = try current.restaurants(in: "Tokyo", requestID: UUID())
    let displayed = try current.displayedContext(for: initial, orderedCardIDs: initial.cards.map(\.id))
    let corrected = SourceFixture("A", "Ume Table", neighborhood: "Shibuya", reason: "Good for counter seating",
                                  revision: 2, correction: (.reason, "Ask for counter seating"))
    let updated = [corrected] + rows.dropFirst()
    let serialized = try JSONEncoder().encode(updated.map(\.row))
    let restored = try JSONDecoder().decode([SavedPlaceMention].self, from: serialized)
    let reopened = try SavedPlaceCatalog(scope: scope,
        authority: .init(sources: updated.map(\.source), records: updated.map(\.pin)),
        mentions: restored, coverage: coverage)
    #expect(throws: SavedPlaceError.staleDisplayedContext) {
        try reopened.originals(for: "A", in: displayed, parentRequestID: initial.requestID)
    }
    let answer = try reopened.restaurants(in: "Tokyo", requestID: UUID())
    let reason = try #require(answer.cards.first?.evidence(for: .reason).first)
    #expect(reason.value == "Ask for counter seating")
    #expect(reason.origin == .domainCorrection)
    let forget = try catalog(updated.filter { $0.row.recordID != "B" })
    let afterForget = try forget.restaurants(in: "Tokyo", requestID: UUID())
    let surviving = try #require(afterForget.cards.first)
    #expect(surviving.members.map(\.recordID) == ["A"])
    #expect(surviving.establishedValue(for: .reason) == "Ask for counter seating")
    #expect(surviving.evidence(for: .address).isEmpty)
    let withdrawn = try catalog(updated.filter { !["A", "B"].contains($0.row.recordID) })
    #expect(try withdrawn.restaurants(in: "Tokyo", requestID: UUID()).cards.map(\.id) == ["C", "D"])
}

@Test func ambiguousListingAndMissingIdentityCannotBridge() throws {
    let ambiguous = fixture() + [.init("G", "Ume Table", neighborhood: "Shibuya", branch: "Shibuya",
                                        address: "Different address", role: .listing)]
    let result = try catalog(ambiguous).restaurants(in: "Tokyo", requestID: UUID())
    #expect(result.cards.first?.members.map(\.recordID) == ["A"])
    #expect(result.cards.first?.evidence(for: .address).isEmpty == true)
    let chain: [SourceFixture] = [
        .init("M", "Cafe", neighborhood: "Shibuya", branch: "Central", address: "First address"),
        .init("N", "Cafe", neighborhood: "Shibuya", branch: "Central", role: .listing),
        .init("O", "Cafe", neighborhood: "Shibuya", branch: "Central", address: "Second address")
    ]
    let contextual = try catalog(chain).restaurants(in: "Tokyo", requestID: UUID())
    #expect(contextual.cards.map { $0.members.map(\.recordID) } == [["M"], ["O"]])
}

@Test func visitRequiresSeparateExactBranchEvidence() throws {
    let rows: [SourceFixture] = [
        .init("A", "Ume Table", neighborhood: "Shibuya", branch: "Shibuya", address: "2 Example-dori"),
        .init("B", "Ume Table", neighborhood: "Shibuya", branch: "Shibuya", address: "2 Example-dori", role: .visit),
        .init("C", "Ume Table", neighborhood: "Taito", branch: "Ueno"),
        .init("D", "Ume Table", neighborhood: "Taito", role: .visit)
    ]
    let current = try catalog(rows)
    let answer = try current.restaurants(in: "Tokyo", requestID: UUID())
    let context = try current.displayedContext(for: answer, orderedCardIDs: ["A", "C"])
    let visited = try current.visits(in: context, parentRequestID: answer.requestID, requestID: UUID())
    #expect(visited.cards.map(\.id) == ["A"])
    #expect(visited.unresolved.map(\.id) == ["C"])
    #expect(visited.cards.first?.visitEvidence.first?.anchors.first?.source.id == "B")
}

@Test func staleOrFabricatedEvidenceCannotBePublished() throws {
    let rows = fixture()
    let current = try catalog(rows)
    let answer = try current.restaurants(in: "Tokyo", requestID: UUID())
    let context = try current.displayedContext(for: answer, orderedCardIDs: ["A", "C", "D"])
    #expect(throws: SavedPlaceError.invalidDisplayedOrder) {
        try current.displayedContext(for: answer, orderedCardIDs: ["A", "A", "D"])
    }
    #expect(throws: SavedPlaceError.staleDisplayedContext) {
        try current.refine(context, parentRequestID: UUID(), neighborhood: "Shibuya", requestID: UUID())
    }
    let authority = AuthoritySnapshot(sources: rows.map(\.source), records: rows.map(\.pin))
    let a = rows[0].row
    let badFact = SavedPlaceFact(.address, value: "invented",
        anchors: [.init(source: a.source, observationID: "0", quote: "invented")], extractorVersion: "fake")
    let bad = SavedPlaceMention(recordID: a.recordID, recordRevision: a.recordRevision,
                               source: a.source, facts: a.facts + [badFact])
    #expect(throws: SavedPlaceError.invalidMention) {
        try SavedPlaceCatalog(scope: scope, authority: authority, mentions: [bad], coverage: coverage)
    }
    #expect(throws: SavedPlaceError.invalidMention) {
        try SavedPlaceCatalog(scope: scope, authority: .init(sources: Array(rows.dropFirst().map(\.source)),
                              records: rows.map(\.pin)), mentions: [a], coverage: coverage)
    }
}

@Test func cityVisitLookupDoesNotRequireARecommendation() throws {
    let rows: [SourceFixture] = [
        .init("A", "Saved restaurant"),
        .init("B", "Visited restaurant", role: .visit),
        .init("C", "Visited elsewhere", city: "Yokohama", role: .visit)
    ]
    let current = try catalog(rows)
    let visits = try current.visits(in: "Tokyo", category: "restaurant", requestID: UUID())
    #expect(visits.cards.map(\.id) == ["B"])
    let saves = try current.savedPlaces(in: "Tokyo", requestID: UUID())
    #expect(saves.cards.map(\.id) == ["A"])
    let categorized = try current.savedPlaces(in: "Tokyo", category: "cafe", requestID: UUID())
    #expect(categorized.cards.isEmpty)
    #expect(categorized.unresolved.isEmpty)
}

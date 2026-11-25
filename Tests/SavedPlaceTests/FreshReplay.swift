import Foundation
import IBrain
import IBrainRetrieval
import Testing

/// Diagnostic only: independent human-authored fixture labels, projected from
/// the evaluator's actual OCR. No model extraction or intent is credited.
@Test func freshLabelReplaySeparatesBranchLifecycleAndVisit() throws {
    let scope = MemoryScope(ownerID: "fictional-eval", namespace: "saved-places-v1.1-replay")
    let url = try #require(Bundle.module.url(forResource: "FRESH-OCR", withExtension: "json",
                                              subdirectory: "Fixtures"))
    let ocr = try JSONDecoder().decode([String: [SourceObservation]].self, from: Data(contentsOf: url))
    let snapshots = ocr.mapValues { observations in observations }
    func row(_ id: String, _ fields: [(SavedPlaceField, String, [(String, String)])]) throws
        -> (SourceSnapshot, SavedPlaceMention) {
        let ref = SourceReference(id: id, revision: 1, fingerprint: "retained-ocr-\(id)")
        let observations = try #require(snapshots[id])
        return (
            SourceSnapshot(reference: ref, scope: scope, observations: observations),
            SavedPlaceMention(recordID: id, recordRevision: 1, source: ref, facts: fields.map { field, value, lines in
                .init(field, value: value, anchors: lines.map { line, quote in
                    .init(source: ref, observationID: line, quote: quote)
                }, extractorVersion: "independent-label-replay")
            })
        )
    }
    let rows = try [
        row("source-01", [
            (.name, "Lantern Kissa", [("5", "Lantern Kissa")]),
            (.city, "Osaka", [("6", "Osaka")]),
            (.branch, "Namba", [("5", "Namba branch")]),
            (.subjectRole, "recommendation", [("5", "Try Lantern Kissa")]),
            (.reason, "Ask for a window seat if there's one free.",
                [("6", "Ask for a window seat if there's"), ("7", "one free.")])
        ]),
        row("source-02", [
            (.name, "Lantern Kissa", [("3", "Lantern Kissa")]),
            (.city, "Osaka", [("7", "Osaka")]),
            (.branch, "Namba", [("3", "Lantern Kissa / Namba")]),
            (.neighborhood, "Namba", [("4", "Namba, Osaka")]),
            (.category, "cafe", [("4", "Cafe")]),
            (.address, "2-18 Lantern Walk Namba, Chuo Ward Osaka",
                [("5", "2-18 Lantern Walk"), ("6", "Namba, Chuo Ward"), ("7", "Osaka")]),
            (.subjectRole, "listing", [("2", "Osaka food guide")])
        ]),
        row("source-03", [
            (.name, "Lantern Kissa", [("5", "Lantern Kissa")]),
            (.city, "Osaka", [("6", "Osaka")]),
            (.branch, "Umeda", [("5", "Umeda branch")]),
            (.category, "cafe", [("6", "cafe list")]),
            (.subjectRole, "recommendation", [("5", "Add Lantern Kissa"), ("6", "to our cafe list too.")]),
            (.reason, "morning set is good.", [("7", "morning set is good.")])
        ]),
        row("source-04", [
            (.name, "Cloud Spoon Cafe", [("5", "Cloud Spoon Cafe")]),
            (.city, "Osaka", [("5", "Osaka")]),
            (.category, "cafe", [("5", "Cafe")]),
            (.subjectRole, "recommendation", [("5", "Try Cloud Spoon Cafe")]),
            (.reason, "ginger pudding", [("6", "ginger pudding")])
        ]),
        row("source-05", [
            (.name, "Amber Steps Cafe", [("7", "Amber Steps Cafe")]),
            (.subjectRole, "incidental", [("6", "Nearby map labels"), ("7", "Amber Steps Cafe")])
        ]),
        row("source-06", [
            (.name, "Paper Ferry Cafe", [("5", "Paper Ferry Cafe")]),
            (.city, "Osaka", [("6", "Osaka")]),
            (.neighborhood, "Namba", [("5", "Namba")]),
            (.category, "cafe", [("5", "Cafe")]),
            (.subjectRole, "visit", [("5", "I went to Paper Ferry Cafe")]),
            (.visitDate, "October 28, 2026", [("4", "October 28, 2026"), ("6", "on October 28.")])
        ]),
        row("source-07", [
            (.name, "Cloud Spoon Cafe", [("5", "Cloud Spoon Cafe")]),
            (.city, "Kyoto", [("5", "Kyoto")]),
            (.category, "cafe", [("5", "Cafe")]),
            (.subjectRole, "recommendation", [("5", "Save Cloud Spoon Cafe in Kyoto")]),
            (.reason, "black sesame pudding", [("6", "black sesame"), ("7", "pudding")])
        ])
    ]
    func catalog(_ rows: [(SourceSnapshot, SavedPlaceMention)]) throws -> SavedPlaceCatalog {
        let sources = rows.map(\.0)
        let mentions = rows.map(\.1)
        let records = mentions.map {
            DomainRecordPin(id: $0.recordID, revision: $0.recordRevision, sources: [$0.source], recordKind: .worldEntity)
        }
        return try SavedPlaceCatalog(scope: scope, authority: .init(sources: sources, records: records),
                                     mentions: mentions, coverage: .init(pendingSourceCount: 0, unresolvedSourceCount: 0))
    }
    let current = try catalog(rows)
    let shortlist = try current.savedPlaces(in: "Osaka", category: "cafe", requestID: UUID())
    #expect(shortlist.cards.map(\.id) == ["source-01", "source-03", "source-04"])
    let namba = try #require(shortlist.cards.first)
    #expect(namba.sources.map(\.id) == ["source-01", "source-02"])
    #expect(namba.evidence(for: .address).flatMap(\.anchors).allSatisfy { $0.source.id == "source-02" })
    #expect(namba.establishedValue(for: .reason) == "Ask for a window seat if there's one free.")
    let prior = try current.displayedContext(for: shortlist, orderedCardIDs: shortlist.cards.map(\.id))
    let refinement = try current.refine(prior, parentRequestID: shortlist.requestID, neighborhood: "Namba", requestID: UUID())
    #expect(refinement.cards.map(\.id) == ["source-01"])
    let visits = try current.visits(in: "Osaka", category: "cafe", requestID: UUID())
    #expect(visits.cards.map(\.id) == ["source-06"])
    #expect(visits.cards.first?.establishedValue(for: .visitDate) == "October 28, 2026")
    let kyoto = try current.savedPlaces(in: "Kyoto", requestID: UUID())
    #expect(kyoto.cards.map(\.id) == ["source-07"])
    #expect(kyoto.cards.first?.establishedValue(for: .reason) == "black sesame pudding")

    let reopened = try catalog(rows.filter { $0.0.reference.id != "source-02" })
    let rebuilt = try reopened.savedPlaces(in: "Osaka", category: "cafe", requestID: UUID())
    let surviving = try #require(rebuilt.unresolved.first)
    #expect(surviving.id == namba.id)
    #expect(surviving.sources.map(\.id) == ["source-01"])
    #expect(surviving.evidence(for: .address).isEmpty)
    #expect(surviving.establishedValue(for: .branch) == "Namba")
    #expect(surviving.establishedValue(for: .reason) == namba.establishedValue(for: .reason))
    #expect(throws: SavedPlaceError.staleDisplayedContext) {
        try reopened.originals(for: namba.id, in: prior, parentRequestID: shortlist.requestID)
    }
}

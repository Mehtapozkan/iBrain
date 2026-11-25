import Foundation
import Testing
import IBrain
import IBrainSemantics
import IBrainRetrieval

// These receipts are deliberately authored. They exercise admission, exhaustive
// execution and lifecycle fences; they do not qualify model comprehension.
struct SavedBank: Decodable {
    struct Source: Decodable { let id: String; let heading: String?; let body: [String]; let readAssessment: String }
    struct Question: Decodable { let id: String; let question: String; let expectedIncluded: [String]? }
    let sources: [Source]; let baseSourceIDs: [String]; let questions: [Question]
    static func load() throws -> SavedBank {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/SavedContent/BANK-v1.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
struct SavedControl {
    let directory: URL
    let scope: MemoryScope
    let store: MemoryStore
    let session: SavedContentQuestionSession
    var sources: [SourceSnapshot]
    var projections: [WorldMemoryProjection]
    var catalog: SavedContentCatalog {
        .init(id: "AUTHORED-catalog", sourceIDs: Set(sources.map { $0.reference.id }), recordIDs: Set(projections.map(\.recordID)))
    }
    static func source(_ item: SavedBank.Source, scope: MemoryScope) throws -> SourceSnapshot {
        let ref = SourceReference(id: item.id, revision: 1, fingerprint: "AUTHORED-" + item.id)
        var observations = item.heading.map { [SourceObservation(id: "heading", value: $0)] } ?? []
        observations += item.body.enumerated().map { .init(id: "body-\($0.offset)", value: $0.element) }
        let coverage = SourceReadCoverage(rawValue: item.readAssessment)
        let assessment = try coverage.map { try SourceReadAssessment(source: ref, coverage: $0, reader: "AUTHORED-NOT-OCR", receiptSHA256: String(repeating: "a", count: 64), observations: observations) }
        return .init(reference: ref, scope: scope, observations: observations, readAssessment: assessment)
    }
    init(allSources: Bool = false, pageSize: Int = 2, scale: Int? = nil) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ibrain-saved-control-" + UUID().uuidString)
        scope = .init(ownerID: "AUTHORED", namespace: "saved-content-control")
        let bank = try SavedBank.load()
        let items: [SavedBank.Source]
        if let scale {
            items = (0..<scale).map { .init(id: String(format: "scale-%03d", $0), heading: "Document \($0)", body: [$0 == scale - 1 ? "A restaurant income idea after the first page." : "An unrelated document."], readAssessment: "readable") }
        } else { items = bank.sources.filter { allSources || bank.baseSourceIDs.contains($0.id) } }
        let sourceScope = scope
        sources = try items.map { try Self.source($0, scope: sourceScope) }
        projections = try sources.filter { !$0.observations.isEmpty }.map { try SavedTextProjection.project($0, recordID: "record-" + $0.reference.id, recordRevision: 1, titleObservationID: "heading") }
        store = try MemoryStore(directory: directory, scope: scope)
        session = try SavedContentQuestionSession(store: store, budget: .init(maximumRecordsPerPage: pageSize))
        try await install()
    }
    var authority: AuthoritySnapshot { .init(sources: sources, records: projections.map { .init(id: $0.recordID, revision: $0.recordRevision, sources: $0.sources, recordKind: .worldEntity) }) }
    func install() async throws {
        try await store.synchronize(authority)
        _ = try await store.applyWorldBatch(projections.map { WorldMemoryWrite($0) }, permit: store.permit())
    }
    func close() async { await store.close(); try? FileManager.default.removeItem(at: directory) }
    func prepare(_ question: String = "What restaurant business ideas did I save?", context: SavedContentDisplayedContext? = nil) async throws -> PreparedSavedContentQuestion {
        try await session.prepare(question: question, taskID: "AUTHORED-" + UUID().uuidString, requestID: UUID(), catalog: catalog, context: context)
    }
    func answer(_ question: String = "What restaurant business ideas did I save?", included: Set<String> = ["s01", "s02", "s03", "s06"], operation: String = "search", basis: String = "currentSaved", context: SavedContentDisplayedContext? = nil) async throws -> SavedContentAnswer {
        let p = try await prepare(question, context: context)
        try await session.validatePrepared(p, activeRequestID: p.requestID)
        var progress = try await session.start(savedMeaning(p.task, operation: operation, basis: basis), for: p, activeRequestID: p.requestID)
        while let task = progress.nextTask {
            #expect(progress.answer == nil)
            try await session.validatePendingPage(activeRequestID: p.requestID)
            progress = try await session.advance(savedPage(task, included: included, sources: sources), activeRequestID: p.requestID)
        }
        return try await session.admit(#require(progress.answer), activeRequestID: p.requestID)
    }
}
func savedReceipt(_ task: ChoiceTask, choices: [String: String]) throws -> DecisionReceipt {
    .init(provider: "AUTHORED-OFFLINE-CONTROL", model: "NO-INFERENCE", requestSHA256: try task.digest(), answers: choices.mapValues { .init(choice: $0) }, elapsedSeconds: 0)
}
func savedMeaning(_ task: ChoiceTask, operation: String = "search", basis: String = "currentSaved", target: String = "none") throws -> DecisionReceipt {
    try savedReceipt(task, choices: ["operation": operation, "basis": basis, "target": target])
}
private func savedPage(_ task: ChoiceTask, included: Set<String>, sources: [SourceSnapshot], unclear: Set<String> = []) throws -> DecisionReceipt {
    let state = try JSONSerialization.jsonObject(with: Data(task.state.utf8)) as! [String: Any]
    let items = state["items"] as! [[String: Any]]
    var choices: [String: String] = [:]
    for (i, item) in items.enumerated() {
        let facts = item["facts"] as! [[String: String]]
        // Exact authored label assignment, using full observed body to disambiguate
        // duplicate titles. This is not a fake lexical intelligence baseline.
        let text = Set(facts.map { $0["text"]! })
        let ids = sources.filter { source in source.observations.contains { text.contains($0.value) } }.map { $0.reference.id }
        let yes = !included.isDisjoint(with: ids), unknown = !unclear.isDisjoint(with: ids)
        choices["match_\(i)"] = unknown ? "unclear" : yes ? "relevant" : "notRelevant"
        for j in facts.indices { choices["fact_\(i)_\(j)"] = yes || unknown ? "required" : "optional" }
    }
    return try savedReceipt(task, choices: choices)
}
private func savedReject(_ action: () async throws -> Void) async {
    do { try await action(); Issue.record("Accepted invalid/stale saved-content operation") } catch {}
}
private func savedIDs(_ answer: SavedContentAnswer) -> Set<String> { Set(answer.cards.map { String($0.recordID.dropFirst(7)) }) }

@Test func savedContentWholeScopeEvidenceAndNegationSurvivePaging() async throws {
    let f = try await SavedControl()
    let a = try await f.answer()
    #expect(savedIDs(a) == ["s01", "s02", "s03", "s06"])
    #expect(a.pageReceipts.count == 4 && a.coverage.visitedRecords == 7 && a.coverage.allAdmittedRecordsVisited)
    #expect(!a.coverage.hasEvidenceLimitations && !a.coverage.canAssertCompletePersonalLibrary)
    #expect(a.originals.isEmpty)
    let bundle = try #require(a.cards.first { $0.recordID == "record-s03" })
    #expect(bundle.summaryText.contains("does not renew automatically") && bundle.summaryText.contains("not a subscription"))
    #expect(a.cards.flatMap(\.facts).allSatisfy { fact in fact.origin == .observed && fact.anchors.allSatisfy { anchor in f.sources.contains { $0.reference == anchor.source && $0.observations.contains { $0.id == anchor.observationID && $0.value.contains(anchor.quote) } } } })
    #expect(a.cards.allSatisfy { !$0.summaryText.contains("$9999") })
    await f.close()
}
@Test func savedContentActualDisplayOrderAndExactMembershipControlFollowups() async throws {
    var f = try await SavedControl()
    let a = try await f.answer()
    let order = ["record-s03", "record-s01", "record-s06", "record-s02"]
    let context = try await f.session.contextForDisplayedAnswer(a, orderedRecordIDs: order, activeRequestID: a.requestID)
    let new = try SavedControl.source(.init(id: "s10", heading: "A cafe tasting club", body: ["Charge cafe guests a recurring monthly membership for tasting evenings."], readAssessment: "readable"), scope: f.scope)
    f.sources.append(new)
    f.projections.append(try SavedTextProjection.project(new, recordID: "record-s10", recordRevision: 1, titleObservationID: "heading"))
    try await f.install()
    let mentions = try await f.answer("Which of those mention subscriptions?", included: ["s01", "s03", "s06"], operation: "filter", context: context)
    #expect(savedIDs(mentions) == ["s01", "s03", "s06"] && mentions.coverage.visitedRecords == 4)
    let offers = try await f.answer("Which of those propose recurring subscriptions?", included: ["s01", "s06", "s10"], operation: "filter", context: context)
    #expect(savedIDs(offers) == ["s01", "s06"])
    let p = try await f.prepare("Open the second one.", context: context)
    let opened = try await f.session.start(savedMeaning(p.task, operation: "originals", target: "row_2"), for: p, activeRequestID: p.requestID)
    let original = try #require(opened.answer)
    #expect(original.originals.count == 1 && original.originals[0].recordID == "record-s01")
    #expect(original.originals[0].sources == [f.sources[0].reference] && original.cards.isEmpty && original.pageReceipts.isEmpty)
    let fresh = try await f.answer(included: ["s01", "s02", "s03", "s06", "s10"])
    #expect(savedIDs(fresh).contains("s10"))
    await f.close()
}
@Test func savedContentPartialUnreadAndNoMatchRemainDifferent() async throws {
    let f = try await SavedControl(allSources: true)
    let a = try await f.answer(included: ["s01", "s02", "s03", "s06", "s08"])
    #expect(a.coverage.allAdmittedRecordsVisited && a.coverage.hasEvidenceLimitations)
    #expect(a.coverage.partialSources.map(\.id) == ["s08"] && a.coverage.unreadSources.map(\.id) == ["s09"])
    #expect(a.coverage.sourcesWithoutProjection.map(\.id) == ["s09"])
    #expect(a.cards.first { $0.recordID == "record-s08" }?.sourceReadings.first?.warning == .readerReportedPartial)
    let ctx = try await f.session.contextForDisplayedAnswer(a, orderedRecordIDs: a.cards.map(\.recordID), activeRequestID: a.requestID)
    let no = try await f.answer("Which of those describe robot waiters?", included: [], operation: "filter", context: ctx)
    #expect(no.cards.isEmpty && no.coverage.unresolvedRecordIDs.isEmpty && no.coverage.visitedRecords == 5)
    #expect(no.coverage.partialSources.map(\.id) == ["s08"])
    await f.close()
}
@Test func savedContentExhaustive65RecordsFindsLastWithoutPrematureAnswer() async throws {
    let f = try await SavedControl(pageSize: 7, scale: 65)
    let a = try await f.answer(included: ["scale-064"])
    #expect(a.coverage.visitedRecords == 65 && a.coverage.allAdmittedRecordsVisited)
    #expect(a.pageReceipts.count == 10 && savedIDs(a) == ["scale-064"])
    await f.close()
}
@Test func savedContentUnsupportedAndAbsentContextNeverDispatchEvidence() async throws {
    let f = try await SavedControl()
    let a = try await f.answer("Add up every monthly price and buy the cheapest plan.", operation: "unsupported")
    #expect(!a.isExecutable && !a.coverage.wasExecuted && !a.coverage.allAdmittedRecordsVisited)
    #expect(a.cards.isEmpty && a.originals.isEmpty && a.pageReceipts.isEmpty)
    let p = try await f.prepare("Which of those mention subscriptions?")
    await savedReject { _ = try await f.session.start(savedMeaning(p.task, operation: "filter"), for: p, activeRequestID: p.requestID) }
    #expect(throws: (any Error).self) { try SavedContentQuestionPlanning.compileMeaning(savedMeaning(p.task, operation: "originals", target: "row_2"), task: p.task) }
    await f.close()
}
@Test func savedContentReceiptBindingConfidenceAndRelevantEvidenceAreMandatory() async throws {
    let f = try await SavedControl()
    let p = try await f.prepare()
    let alien = try SavedContentQuestionPlanning.meaningTask(taskID: "other", requestID: p.requestID, question: "What restaurant business ideas did I save?", catalogBindingSHA256: "different")
    await savedReject { _ = try await f.session.start(savedMeaning(alien), for: p, activeRequestID: p.requestID) }
    let progress = try await f.session.start(savedMeaning(p.task), for: p, activeRequestID: p.requestID)
    let task = try #require(progress.nextTask)
    var empty = try savedPage(task, included: [], sources: f.sources).answers.mapValues(\.choice)
    empty["match_0"] = "relevant"
    await savedReject { _ = try await f.session.advance(savedReceipt(task, choices: empty), activeRequestID: p.requestID) }
    let valid = try savedPage(task, included: ["s01", "s02"], sources: f.sources)
    let low = Dictionary(uniqueKeysWithValues: valid.answers.map { key, answer in
        (key, ChoiceAnswer(choice: answer.choice, confidence: 0.2, probabilities: Dictionary(uniqueKeysWithValues: task.questions[key]!.criteria.keys.map { ($0, $0 == answer.choice ? 1.0 : 0.0) })))
    })
    let receipt = DecisionReceipt(provider: "jev", model: "jev-1.13.0", requestSHA256: try task.digest(), answers: low, elapsedSeconds: 0)
    await savedReject { _ = try await f.session.advance(receipt, activeRequestID: p.requestID) }
    _ = try await f.session.advance(valid, activeRequestID: p.requestID)
    await savedReject { _ = try await f.session.advance(valid, activeRequestID: p.requestID) }
    await f.close()
}
@Test func savedContentCancelForgetRevisionAndReplacementFencePublication() async throws {
    for mode in ["cancel", "forget", "revision", "replace"] {
        let f = try await SavedControl()
        let a = try await f.answer()
        let ctx = try await f.session.contextForDisplayedAnswer(a, orderedRecordIDs: a.cards.map(\.recordID), activeRequestID: a.requestID)
        let p = try await f.prepare(context: ctx)
        if mode == "cancel" { await f.session.cancel() }
        if mode == "forget" { try await f.store.invalidateSource(id: "s01", forget: true) }
        if mode == "revision" {
            let source = f.sources[0]
            let changed = SourceSnapshot(reference: .init(id: "s01", revision: 2, fingerprint: "changed"), scope: f.scope, observations: source.observations)
            try await f.store.synchronize(.init(sources: [changed] + Array(f.sources.dropFirst()), records: []))
        }
        if mode == "replace" { _ = try await f.prepare() }
        await savedReject { try await f.session.validatePrepared(p, activeRequestID: p.requestID) }
        await savedReject { _ = try await f.session.start(savedMeaning(p.task), for: p, activeRequestID: p.requestID) }
        await savedReject { _ = try await f.session.admit(a, activeRequestID: a.requestID) }
        if mode != "replace" { await savedReject { _ = try await f.prepare(context: ctx) } }
        await f.close()
    }
}
@Test func savedContentForgetKeepsIndependentDuplicateAndColdStoreCannotRestoreContext() async throws {
    var f = try await SavedControl()
    let a = try await f.answer()
    let ctx = try await f.session.contextForDisplayedAnswer(a, orderedRecordIDs: a.cards.map(\.recordID), activeRequestID: a.requestID)
    try await f.store.invalidateSource(id: "s01", forget: true)
    f.sources.removeAll { $0.reference.id == "s01" }; f.projections.removeAll { $0.recordID == "record-s01" }
    try await f.store.synchronize(f.authority)
    let next = try await f.answer(included: ["s01", "s02", "s03", "s06"])
    #expect(savedIDs(next) == ["s02", "s03", "s06"])
    await savedReject { _ = try await f.prepare(context: ctx) }
    await f.store.close()
    let reopened = try MemoryStore(directory: f.directory, scope: f.scope)
    try await reopened.synchronize(f.authority)
    let rows = try await reopened.worldSearchSnapshot(permit: reopened.permit())
    #expect(rows.entities.count == 6 && rows.entities.contains { $0.projection.recordID == "record-s06" })
    let newSession = try SavedContentQuestionSession(store: reopened)
    await savedReject { _ = try await newSession.prepare(question: "Open the first one.", taskID: "cold", requestID: UUID(), catalog: f.catalog, context: ctx) }
    await reopened.close(); try? FileManager.default.removeItem(at: f.directory)
}
@Test func savedContentNativeCorrectionPersistsWithItsOriginAndPrintedTextIsSeparate() async throws {
    var f = try await SavedControl()
    let before = try await f.answer()
    let oldContext = try await f.session.contextForDisplayedAnswer(before, orderedRecordIDs: before.cards.map(\.recordID), activeRequestID: before.requestID)
    let old = try #require(try await f.store.worldSearchSnapshot(permit: f.store.permit()).entities.first { $0.projection.recordID == "record-s01" })
    let corrected = WorldClaim(id: "owner-title", predicate: .name, value: .text("My dining-room membership experiment"), origin: .domainCorrection, anchors: [old.projection.claims[0].anchors[0]], extractorVersion: "AUTHORED-native-confirmed-correction")
    let projection = WorldMemoryProjection(recordID: "record-s01", recordRevision: 2, scope: f.scope, kind: .document, claims: old.projection.claims.filter { $0.predicate != .name } + [corrected])
    f.projections[0] = projection
    try await f.store.synchronize(f.authority)
    _ = try await f.store.applyWorldBatch([WorldMemoryWrite(projection, expectedMemoryRevision: old.revision)], permit: f.store.permit())
    await savedReject { _ = try await f.prepare(context: oldContext) }
    let current = try await f.answer()
    #expect(current.cards.first { $0.recordID == "record-s01" }?.title?.origin == .domainCorrection)
    #expect(current.cards.first { $0.recordID == "record-s01" }?.title?.text == "My dining-room membership experiment")
    let printed = try await f.answer("What is printed on the saved ideas?", basis: "printed")
    #expect(printed.cards.flatMap(\.facts).allSatisfy { $0.origin == .observed })
    #expect(!printed.cards.flatMap(\.facts).contains { $0.text == "My dining-room membership experiment" })
    await f.store.close()
    let reopened = try MemoryStore(directory: f.directory, scope: f.scope)
    try await reopened.synchronize(f.authority)
    let restored = try await reopened.worldSearchSnapshot(permit: reopened.permit())
    #expect(restored.entities.contains { $0.projection == projection })
    await reopened.close(); try? FileManager.default.removeItem(at: f.directory)
}
@Test func savedContentTextProjectionIsLosslessAndCannotPromoteParaphrases() async throws {
    let scope = MemoryScope(ownerID: "AUTHORED", namespace: "dense")
    let text = String(repeating: "é 👩🏽‍🍳 cafe\n", count: 2500)
    let source = SourceSnapshot(reference: .init(id: "dense", revision: 1, fingerprint: "dense"), scope: scope, observations: [.init(id: "body", value: text)])
    let p = try SavedTextProjection.project(source, recordID: "dense-record", recordRevision: 1)
    #expect(p.claims.count > 1 && p.claims.map { if case .text(let t) = $0.value { return t }; return "" }.joined() == text)
    #expect(p.claims.allSatisfy { $0.anchors.count == 1 && $0.anchors[0].quote.utf8.count <= 12_000 })
    let invented = WorldClaim(id: "unsupported-summary", predicate: .description, value: .text("A guaranteed profitable cafe"), anchors: p.claims[0].anchors, extractorVersion: "AUTHORED")
    #expect(throws: (any Error).self) { try SavedContentTextFact(invented) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try MemoryStore(directory: directory, scope: scope)
    try await store.synchronize(.init(sources: [source], records: [.init(id: p.recordID, revision: 1, sources: p.sources, recordKind: .worldEntity)]))
    _ = try await store.applyWorldBatch([WorldMemoryWrite(p)], permit: store.permit())
    #expect(try await store.worldSearchSnapshot(permit: store.permit()).entities[0].projection == p)
    await store.close()
    try? FileManager.default.removeItem(at: directory)
}

@Test func savedContentPendingNativePreparationIsNotCompleteEvenWithReadableText() async throws {
    let f = try await SavedControl()
    let pending = f.sources[0].reference
    try await f.store.synchronize(.init(sources: f.sources, records: f.authority.records, pendingSourcePreparations: [pending]))
    let a = try await f.answer()
    #expect(a.coverage.pendingSourcePreparations == [pending])
    #expect(a.coverage.allAdmittedRecordsVisited && a.coverage.hasEvidenceLimitations)
    await f.close()
}
@Test func savedContentInFlightPageCannotSurviveSourceChangeOrCancellation() async throws {
    for mode in ["cancel", "sourceChanged", "unrelatedAdded"] {
        let f = try await SavedControl()
        let p = try await f.prepare()
        let progress = try await f.session.start(savedMeaning(p.task), for: p, activeRequestID: p.requestID)
        let task = try #require(progress.nextTask)
        let receipt = try savedPage(task, included: ["s01", "s02"], sources: f.sources)
        if mode == "cancel" { await f.session.cancel() }
        else if mode == "sourceChanged" { try await f.store.invalidateSource(id: "s01", forget: false) }
        else {
            let added = try SavedControl.source(.init(id: "extra", heading: "New item", body: ["Other evidence"], readAssessment: "readable"), scope: f.scope)
            try await f.store.synchronize(.init(sources: f.sources + [added], records: f.authority.records))
        }
        await savedReject { try await f.session.validatePendingPage(activeRequestID: p.requestID) }
        await savedReject { _ = try await f.session.advance(receipt, activeRequestID: p.requestID) }
        await f.close()
    }
}

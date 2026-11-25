import Foundation
import Testing
import IBrain
import IBrainSemantics
import IBrainRetrieval

private struct SavedReplayPending: Error {}
private struct SavedTextReceiptFiles {
    let directory: URL
    func write<T: Encodable>(_ value: T, _ name: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    func receipt(_ task: ChoiceTask) throws -> DecisionReceipt {
        let hash = try task.digest()
        let file = directory.appendingPathComponent("receipts/" + hash + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            struct Request: Encodable { let status, requestSHA256, taskFile, receiptFile: String; let task: ChoiceTask }
            try write(task, "TASK.json")
            try write(Request(status: "PENDING_GENUINE_PROVIDER_RECEIPT; NO_DISPATCH_BY_THIS_RUNNER", requestSHA256: hash, taskFile: "TASK.json", receiptFile: file.path, task: task), "REQUEST.json")
            throw SavedReplayPending()
        }
        let receipt = try JSONDecoder().decode(DecisionReceipt.self, from: Data(contentsOf: file))
        guard receipt.provider != "AUTHORED-OFFLINE-CONTROL", receipt.model != "NO-INFERENCE" else { throw SemanticError.invalidReceipt }
        try receipt.validate(for: task)
        return receipt
    }
    func answer(_ f: SavedControl, question: String, key: Int, context: SavedContentDisplayedContext? = nil) async throws -> SavedContentAnswer {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", key))!
        let p = try await f.session.prepare(question: question, taskID: "saved-text-frozen-\(key)", requestID: id, catalog: f.catalog, context: context)
        try await f.session.validatePrepared(p, activeRequestID: id)
        var progress = try await f.session.start(receipt(p.task), for: p, activeRequestID: id)
        while let task = progress.nextTask {
            try await f.session.validatePendingPage(activeRequestID: id)
            progress = try await f.session.advance(receipt(task), activeRequestID: id)
        }
        guard let answer = progress.answer else { throw SemanticError.invalidReceipt }
        return try await f.session.admit(answer, activeRequestID: id)
    }
}
private struct SavedTextCaseResult: Encodable {
    struct Support: Encodable {
        let recordID: String
        let recordRevision: Int
        let sources: [SourceReference]
        let facts: [SavedContentTextFact]
    }
    let id, question, operation: String
    let expectedSources, actualSources, unresolvedRecords, originalSources: [String]
    let passed: Bool
    let failures: [String]
    let extracts: [String: String]
    let receiptHashes: [String]
    let coverage: String
    let support: [Support]
    let originalSupport: [Support]
    let coverageSources: [String: [String]]
}

/// Incremental replay/export ONLY. Pin's single live dispatcher supplies retained
/// genuine receipts by exact task hash. No network/model code or automatic retry.
/// PENDING is not a passing semantic verdict even when this control test returns.
@Test func savedContentActualTextReplay() async throws {
    guard let path = ProcessInfo.processInfo.environment["SAVED_CONTENT_ACTUAL_TEXT_DIR"] else { return }
    let files = SavedTextReceiptFiles(directory: URL(fileURLWithPath: path))
    try FileManager.default.createDirectory(at: files.directory.appendingPathComponent("receipts"), withIntermediateDirectories: true)
    let bank = try SavedBank.load()
    var results: [SavedTextCaseResult] = []
    struct Run: Encodable { let status: String; let newProviderCallsByRunner: Int; let results: [SavedTextCaseResult]; let limits: String }
    func record(_ status: String) throws {
        try files.write(Run(status: status, newProviderCallsByRunner: 0, results: results, limits: "Correct fictional text only. No image reading, native rendering, physical phone, or search comparison verdict. Provider provenance/cost/dispatch ledger remains Pin-owned."), "RUN.json")
    }
    let cases = bank.questions + [.init(id: "fresh-library-after-add", question: bank.questions[0].question, expectedIncluded: ["s01", "s02", "s03", "s06", "s10"])]
    for (index, q) in cases.enumerated() {
        var f = try await SavedControl(allSources: q.id == "partial-unread", pageSize: 12)
        do {
            let followup = ["mentions", "offers", "explicit-no-renewal", "new-source-filter", "no-match", "original-order"].contains(q.id)
            var context: SavedContentDisplayedContext?
            if followup {
                let parent = try await files.answer(f, question: bank.questions[0].question, key: 1)
                let preferred = ["record-s03", "record-s01", "record-s06", "record-s02"]
                let order = preferred.filter { id in parent.cards.contains { $0.recordID == id } } + parent.cards.map(\.recordID).filter { !preferred.contains($0) }
                context = try await f.session.contextForDisplayedAnswer(parent, orderedRecordIDs: order, activeRequestID: parent.requestID, displayIdentity: UUID(uuidString: "00000000-0000-0000-0000-000000001001")!)
            }
            if ["new-source-filter", "fresh-library-after-add"].contains(q.id) {
                let source = try SavedControl.source(.init(id: "s10", heading: "A cafe tasting club", body: ["Charge cafe guests a recurring monthly membership for tasting evenings."], readAssessment: "readable"), scope: f.scope)
                f.sources.append(source); f.projections.append(try SavedTextProjection.project(source, recordID: "record-s10", recordRevision: 1, titleObservationID: "heading"))
                try await f.install()
            }
            let a = try await files.answer(f, question: q.question, key: index + 1, context: context)
            let actual = a.cards.map { String($0.recordID.dropFirst(7)) }.sorted()
            let expected = (q.expectedIncluded ?? []).sorted()
            var failures: [String] = []
            if actual != expected { failures.append("result membership") }
            if !a.coverage.unresolvedRecordIDs.isEmpty { failures.append("unexpected unresolved matches") }
            let desiredOperation = q.id == "arithmetic" ? "unsupported" : q.id == "original-order" ? "originals" : followup ? "filter" : "search"
            if a.meaning.operation.rawValue != desiredOperation { failures.append("whole request operation") }
            let originalIDs = a.originals.flatMap(\.sources).map(\.id).sorted()
            if originalIDs != (q.id == "original-order" ? ["s01"] : []) { failures.append("original target") }
            let extracts = Dictionary(uniqueKeysWithValues: a.cards.map { ($0.recordID, $0.summaryText) })
            // Required discriminating evidence, frozen source text rather than
            // lexical matching as a replacement for semantic decisions.
            for card in a.cards {
                let sourceID = String(card.recordID.dropFirst(7))
                let body = bank.sources.first { $0.id == sourceID }?.body ?? []
                let needed: [String]
                if ["topic", "paraphrase", "partial-unread", "fresh-library-after-add"].contains(q.id) {
                    needed = sourceID == "s03" ? Array(body.prefix(2)) : sourceID == "s02" ? body : Array(body.prefix(1))
                } else if q.id == "explicit-no-renewal" { needed = [body[1]] }
                else if ["offers", "new-source-filter"].contains(q.id) { needed = Array(body.prefix(1)) }
                else { needed = [] }
                if !needed.allSatisfy({ card.summaryText.contains($0) }) { failures.append("missing discriminating evidence: " + sourceID) }
                if q.id == "mentions", sourceID == "s03", !card.summaryText.contains("not a subscription"), !card.summaryText.contains("not subscriptions") { failures.append("lost negative subscription mention") }
            }
            if q.id == "partial-unread" {
                if a.coverage.partialSources.map(\.id) != ["s08"] || a.coverage.unreadSources.map(\.id) != ["s09"] || !a.coverage.hasEvidenceLimitations { failures.append("partial/unread coverage") }
            }
            if q.id == "arithmetic", a.coverage.wasExecuted { failures.append("unsupported execution") }
            results.append(.init(id: q.id, question: q.question, operation: a.meaning.operation.rawValue, expectedSources: expected, actualSources: actual, unresolvedRecords: a.coverage.unresolvedRecordIDs, originalSources: originalIDs, passed: failures.isEmpty, failures: failures, extracts: extracts, receiptHashes: [a.meaning.receipt.requestSHA256] + a.pageReceipts.map(\.requestSHA256), coverage: "visited=\(a.coverage.visitedRecords); records=\(a.coverage.declaredRecords); limitations=\(a.coverage.hasEvidenceLimitations)", support: a.cards.map { .init(recordID: $0.recordID, recordRevision: $0.recordRevision, sources: $0.sources, facts: $0.facts) }, originalSupport: a.originals.map { .init(recordID: $0.recordID, recordRevision: $0.recordRevision, sources: $0.sources, facts: []) }, coverageSources: ["partial": a.coverage.partialSources.map(\.id), "unread": a.coverage.unreadSources.map(\.id), "pending": a.coverage.pendingSourcePreparations.map(\.id), "withoutProjection": a.coverage.sourcesWithoutProjection.map(\.id)]))
            await f.close()
            try record("IN_PROGRESS")
        } catch is SavedReplayPending {
            await f.close(); try record("PENDING_GENUINE_PROVIDER_RECEIPT"); return
        } catch {
            await f.close(); try record("ERROR: \(error)"); throw error
        }
    }
    try record(results.allSatisfy(\.passed) ? "PASS_FICTIONAL_TEXT_ONLY" : "FAIL_FICTIONAL_TEXT_ONLY")
}

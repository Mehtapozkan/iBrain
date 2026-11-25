import Foundation
import IBrain
import IBrainSemantics

/// The native index owner declares the current permitted input collection.
/// This is scope metadata, not evidence of complete indexing/reading or a grant.
public struct SavedContentCatalog: Sendable {
    public let id: String
    public let sourceIDs: Set<String>
    public let recordIDs: Set<String>
    public init(id: String, sourceIDs: Set<String>, recordIDs: Set<String>) {
        self.id = id; self.sourceIDs = sourceIDs; self.recordIDs = recordIDs
    }
}
public struct SavedContentBudget: Sendable {
    public let maximumRecordsPerPage: Int
    public init(maximumRecordsPerPage: Int = 12) { self.maximumRecordsPerPage = maximumRecordsPerPage }
}
public struct SavedContentCoverage: Sendable {
    public let wasExecuted: Bool
    public let declaredSources: Int
    public let declaredRecords: Int
    public let visitedRecords: Int
    public let unprojectedRecordIDs: [String]
    public let unreadSources: [SourceReference]
    /// Current sources with readable text observations and no separate reader assessment.
    public let textObservedWithoutAssessment: [SourceReference]
    public let partialSources: [SourceReference]
    public let noReadableDetailsSources: [SourceReference]
    public let sourcesWithoutProjection: [SourceReference]
    public let pendingSourcePreparations: [SourceReference]
    public let unresolvedRecordIDs: [String]
    public var allAdmittedRecordsVisited: Bool { wasExecuted && visitedRecords + unprojectedRecordIDs.count == declaredRecords }
    public var hasEvidenceLimitations: Bool {
        !textObservedWithoutAssessment.isEmpty || hasEvidenceLimitationsBeyondUnassessedText
    }
    /// A remaining evidence gap beyond the absence of a separate assessment
    /// for source text that was available to the question.
    public var hasEvidenceLimitationsBeyondUnassessedText: Bool {
        !unprojectedRecordIDs.isEmpty || unreadSources.count > textObservedWithoutAssessment.count ||
        !partialSources.isEmpty || !noReadableDetailsSources.isEmpty || !sourcesWithoutProjection.isEmpty ||
        !pendingSourcePreparations.isEmpty || !unresolvedRecordIDs.isEmpty
    }
    public var canAssertCompletePersonalLibrary: Bool { false }
}
public struct SavedContentSourceReading: Sendable {
    public let source: SourceReference
    public let assessment: SourceReadAssessment?
    public var warning: SourceReadingWarning? {
        switch assessment?.coverage {
        case nil: .unknown
        case .partial: .readerReportedPartial
        case .noReadableDetails: .readerReportedNoReadableDetails
        case .readable: nil
        }
    }
}
public struct SavedContentCard: Sendable {
    public let recordID: String
    public let recordRevision: Int
    public let relevance: SavedContentRelevance
    public let title: SavedContentTextFact?
    public let facts: [SavedContentTextFact]
    public let sources: [SourceReference]
    public let sourceReadings: [SavedContentSourceReading]
    /// A supported extract, not a generated paraphrase or a source instruction.
    public var summaryText: String {
        var seen = Set<String>()
        return facts.filter { seen.insert($0.origin.rawValue + "\u{0}" + $0.text).inserted }.map(\.text).joined(separator: "\n")
    }
}
/// Selection metadata only. Pin must recheck source identity/current access and
/// fetch immutable original bytes through its existing PhotoKit owner.
public struct SavedContentOriginalSelection: Sendable {
    public let recordID: String
    public let recordRevision: Int
    public let sources: [SourceReference]
}
public struct PreparedSavedContentQuestion: Sendable {
    public let task: ChoiceTask
    public let requestID: UUID
    fileprivate let owner: UUID
    fileprivate let generation: Int
    fileprivate let question: String
    fileprivate let catalog: SavedContentCatalog
    fileprivate let binding: String
    fileprivate let rows: [StoredWorldMemory]
    fileprivate let sources: [SourceSnapshot]
    fileprivate let missingRecords: [String]
    fileprivate let pendingSources: [SourceReference]
    fileprivate let context: SavedContentDisplayedContext?
    fileprivate let permit: SnapshotPermit
}
public struct SavedContentAnswer: Sendable {
    public let requestID: UUID
    public let meaning: SavedContentMeaning
    public let cards: [SavedContentCard]
    public let originals: [SavedContentOriginalSelection]
    public let coverage: SavedContentCoverage
    public let pageReceipts: [DecisionReceipt]
    public var isExecutable: Bool { ![.clarify, .unsupported].contains(meaning.operation) }
    fileprivate let prepared: PreparedSavedContentQuestion
    fileprivate let examined: [StoredWorldMemory]
}
/// Process-local capability produced only from an admitted, actually displayed
/// answer. Serialization of its public IDs cannot restore this authority.
public struct SavedContentDisplayedContext: Sendable {
    public let id: UUID
    public let answerRequestID: UUID
    public let bindingSHA256: String
    public let orderedRecordIDs: [String]
    fileprivate let owner: UUID
    fileprivate let catalogID: String
    fileprivate let rows: [StoredWorldMemory]
    fileprivate let titles: [String]
    fileprivate let unclearRecordIDs: Set<String>
    fileprivate let scopedFactIDs: [String: [String]]
    fileprivate let sourcePermits: [SourceReadPermit]
}
public struct SavedContentProgress: Sendable {
    public let requestID: UUID
    public let visitedRecords: Int
    public let totalRecords: Int
    public let nextTask: ChoiceTask?
    public let answer: SavedContentAnswer?
}

/// All scoped candidates are visited in bounded whole-record semantic pages.
/// There is no lexical Top-N shortcut and no new authority or indexing owner.
public actor SavedContentQuestionSession {
    private let store: MemoryStore
    private let budget: SavedContentBudget
    private let identity = UUID()
    private var generation = 0
    private var activeRequest: UUID?
    private var startedRequest: UUID?
    private var currentContext: UUID?
    private var busy = false
    private struct Work {
        let prepared: PreparedSavedContentQuestion
        let meaning: SavedContentMeaning
        let rows: [StoredWorldMemory]
        let items: [SavedContentPageItem]
        var index: Int = 0
        var pageIndex: Int = 0
        var visited: Int = 0
        var selections: [SavedContentPageSelection] = []
        var receipts: [DecisionReceipt] = []
        var page: PreparedSavedContentPage?
    }
    private var work: Work?

    public init(store: MemoryStore, budget: SavedContentBudget = .init()) throws {
        guard (1...128).contains(budget.maximumRecordsPerPage) else { throw SemanticError.unsupportedEvidence }
        self.store = store; self.budget = budget
    }
    public func cancel(clearDisplayedContext: Bool = true) {
        generation += 1; activeRequest = nil; startedRequest = nil; work = nil
        if clearDisplayedContext { currentContext = nil }
    }
    private func current(_ p: PreparedSavedContentQuestion, requestID: UUID) throws {
        guard p.owner == identity, p.generation == generation, p.requestID == requestID,
              activeRequest == requestID else { throw MemoryError.staleResult }
        try Task.checkCancellation()
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private func validateContext(_ context: SavedContentDisplayedContext, catalog: SavedContentCatalog) async throws {
        guard context.owner == identity, context.id == currentContext, context.catalogID == catalog.id,
              Set(context.orderedRecordIDs).isSubset(of: catalog.recordIDs),
              Set(context.rows.flatMap { $0.projection.sources }.map(\.id)).isSubset(of: catalog.sourceIDs) else {
            throw MemoryError.invalidContext
        }
        for permit in context.sourcePermits { try await store.validate(permit) }
        let now = try await store.worldSearchSnapshot(permit: store.permit(), maximumEntities: 4096)
        let currentByID = Dictionary(uniqueKeysWithValues: now.entities.map { ($0.projection.recordID, $0) })
        guard context.rows.allSatisfy({ row in currentByID[row.projection.recordID] == row }) else { throw MemoryError.staleResult }
    }

    public func prepare(question: String, taskID: String, requestID: UUID, catalog: SavedContentCatalog,
                        context: SavedContentDisplayedContext? = nil) async throws -> PreparedSavedContentQuestion {
        guard !busy else { throw SemanticError.existingAttempt }; busy = true; defer { busy = false }
        guard !catalog.id.isEmpty, catalog.sourceIDs.count <= 16_384, catalog.recordIDs.count <= 4096 else { throw SemanticError.unsupportedEvidence }
        generation += 1; let epoch = generation; activeRequest = requestID; startedRequest = nil; work = nil
        if let context { try await validateContext(context, catalog: catalog) }
        let permit = try await store.permit()
        let sourceSnapshot = try await store.sourceSearchSnapshot(permit: permit)
        let inventory = try await store.recordInventory(permit: permit)
        guard catalog.sourceIDs.isSubset(of: Set(sourceSnapshot.sources.map { $0.reference.id })) else { throw MemoryError.invalidEvidence }
        let sourceRows = sourceSnapshot.sources.filter { catalog.sourceIDs.contains($0.reference.id) }.sorted { $0.reference.id < $1.reference.id }
        let world = try await store.worldSearchSnapshot(permit: permit, maximumEntities: 4096)
        let rows = world.entities.filter { catalog.recordIDs.contains($0.projection.recordID) }
        guard rows.allSatisfy({ $0.projection.kind == .document && !$0.projection.sources.isEmpty && Set($0.projection.sources.map(\.id)).isSubset(of: catalog.sourceIDs) }) else {
            throw MemoryError.invalidEvidence
        }
        let pending = sortedSources(inventory.pendingSourcePreparations.filter { catalog.sourceIDs.contains($0.id) })
        struct Binding: Encodable { let id: String; let sourceIDs, recordIDs: [String]; let sources: [SourceSnapshot]; let pendingSources: [SourceReference]; let projections: [WorldMemoryProjection] }
        let binding = ChoiceTask.hash(try encoded(Binding(id: catalog.id, sourceIDs: catalog.sourceIDs.sorted(),
            recordIDs: catalog.recordIDs.sorted(), sources: sourceRows, pendingSources: pending, projections: rows.map(\.projection))))
        let task = try SavedContentQuestionPlanning.meaningTask(taskID: taskID, requestID: requestID, question: question,
            catalogBindingSHA256: binding, displayedTitles: context?.titles ?? [], parentBindingSHA256: context?.bindingSHA256)
        let prepared = PreparedSavedContentQuestion(task: task, requestID: requestID, owner: identity, generation: epoch,
            question: question, catalog: catalog, binding: binding, rows: rows, sources: sourceRows,
            missingRecords: catalog.recordIDs.subtracting(rows.map { $0.projection.recordID }).sorted(), pendingSources: pending, context: context, permit: permit)
        if let context { try await validateContext(context, catalog: catalog) }
        try await store.validate(permit); try current(prepared, requestID: requestID)
        return prepared
    }

    /// Recheck immediately before inference; Pin must additionally recheck its
    /// own source/processing permissions at the actual provider boundary.
    public func validatePrepared(_ prepared: PreparedSavedContentQuestion, activeRequestID: UUID) async throws {
        try current(prepared, requestID: activeRequestID); try await store.validate(prepared.permit)
        if let context = prepared.context { try await validateContext(context, catalog: prepared.catalog) }
        try await store.validate(prepared.permit)
        try current(prepared, requestID: activeRequestID)
    }
    public func validatePendingPage(activeRequestID: UUID) async throws {
        guard let work, work.page != nil else { throw MemoryError.invalidContext }
        try current(work.prepared, requestID: activeRequestID); try await store.validate(work.prepared.permit)
        try current(work.prepared, requestID: activeRequestID)
    }

    /// Start from the genuine meaning receipt. Non-read operations finish here;
    /// reads return the first bounded evidence task, not a partial full answer.
    public func start(_ receipt: DecisionReceipt, for p: PreparedSavedContentQuestion,
                      activeRequestID: UUID) async throws -> SavedContentProgress {
        guard !busy else { throw SemanticError.existingAttempt }; busy = true; defer { busy = false }
        try current(p, requestID: activeRequestID); try await store.validate(p.permit)
        guard startedRequest != activeRequestID else { throw SemanticError.existingAttempt }
        let meaning = try SavedContentQuestionPlanning.compileMeaning(receipt, task: p.task)
        var selected = p.rows
        if meaning.operation == .filter || meaning.operation == .originals {
            guard let context = p.context else { throw MemoryError.invalidContext }
            try await validateContext(context, catalog: p.catalog)
            selected = context.rows
        }
        try current(p, requestID: activeRequestID)
        startedRequest = activeRequestID
        if meaning.operation == .originals {
            if !meaning.allDisplayedOriginals {
                guard let ordinal = meaning.originalOrdinal, selected.indices.contains(ordinal - 1) else { throw MemoryError.invalidContext }
                selected = [selected[ordinal - 1]]
            }
            let originals = selected.map { row in SavedContentOriginalSelection(recordID: row.projection.recordID,
                recordRevision: row.projection.recordRevision, sources: sortedSources(row.projection.sources)) }
            let answer = try await makeAnswer(p, meaning: meaning, rows: selected, selections: [], receipts: [],
                visited: selected.count, originals: originals)
            return .init(requestID: activeRequestID, visitedRecords: selected.count, totalRecords: selected.count, nextTask: nil, answer: answer)
        }
        if meaning.operation == .clarify || meaning.operation == .unsupported {
            let answer = try await makeAnswer(p, meaning: meaning, rows: [], selections: [], receipts: [], visited: 0)
            return .init(requestID: activeRequestID, visitedRecords: 0, totalRecords: 0, nextTask: nil, answer: answer)
        }
        let retained = meaning.operation == .filter ? p.context?.scopedFactIDs ?? [:] : [:]
        let items = try selected.map { row in
            let factIDs = retained[row.projection.recordID].map { Set($0) }
            return try SavedContentPageItem(projection: row.projection, basis: meaning.basis, retainingFactIDs: factIDs)
        }
        var next = Work(prepared: p, meaning: meaning, rows: selected, items: items)
        // A projection without usable text is uncertainty, not a no-match.
        for item in items where item.facts.isEmpty {
            next.selections.append(.init(recordID: item.recordID, relevance: .unclear, selectedFacts: [])); next.visited += 1
        }
        work = next
        return try await progress()
    }

    public func advance(_ receipt: DecisionReceipt, activeRequestID: UUID) async throws -> SavedContentProgress {
        guard !busy else { throw SemanticError.existingAttempt }; busy = true; defer { busy = false }
        guard var currentWork = work, let page = currentWork.page else { throw MemoryError.invalidContext }
        try current(currentWork.prepared, requestID: activeRequestID); try await store.validate(currentWork.prepared.permit)
        let selections = try SavedContentQuestionPlanning.compilePage(receipt, for: page)
        try current(currentWork.prepared, requestID: activeRequestID)
        currentWork.selections += selections; currentWork.visited += selections.count; currentWork.receipts.append(receipt)
        currentWork.page = nil; currentWork.pageIndex += 1; work = currentWork
        return try await progress()
    }
    private func progress() async throws -> SavedContentProgress {
        guard var w = work else { throw MemoryError.invalidContext }
        try current(w.prepared, requestID: w.prepared.requestID); try await store.validate(w.prepared.permit)
        while w.index < w.items.count && w.items[w.index].facts.isEmpty { w.index += 1 }
        if w.index == w.items.count {
            let answer = try await makeAnswer(w.prepared, meaning: w.meaning, rows: w.rows,
                selections: w.selections, receipts: w.receipts, visited: w.visited)
            work = nil
            return .init(requestID: w.prepared.requestID, visitedRecords: w.visited, totalRecords: w.items.count, nextTask: nil, answer: answer)
        }
        var candidates: [SavedContentPageItem] = [], page: PreparedSavedContentPage?
        var cursor = w.index
        while cursor < w.items.count && candidates.count < budget.maximumRecordsPerPage {
            let item = w.items[cursor]
            if item.facts.isEmpty { cursor += 1; continue }
            do {
                let trial = try SavedContentQuestionPlanning.page(taskID: w.prepared.task.id + "/evidence-\(w.pageIndex)",
                    requestID: w.prepared.requestID, question: w.prepared.question, meaning: w.meaning,
                    catalogBindingSHA256: w.prepared.binding, pageIndex: w.pageIndex, items: candidates + [item])
                candidates.append(item); page = trial; cursor += 1
            } catch SemanticError.unsupportedEvidence {
                if candidates.isEmpty { throw SemanticError.unsupportedEvidence }
                break
            }
        }
        guard let page else { throw SemanticError.unsupportedEvidence }
        w.index = cursor; w.page = page; work = w
        return .init(requestID: w.prepared.requestID, visitedRecords: w.visited, totalRecords: w.items.count,
            nextTask: page.task, answer: nil)
    }
    private func sortedSources(_ sources: Set<SourceReference>) -> [SourceReference] {
        sources.sorted { ($0.id, $0.revision, $0.fingerprint) < ($1.id, $1.revision, $1.fingerprint) }
    }
    private func makeAnswer(_ p: PreparedSavedContentQuestion, meaning: SavedContentMeaning, rows: [StoredWorldMemory],
                            selections: [SavedContentPageSelection], receipts: [DecisionReceipt], visited: Int,
                            originals: [SavedContentOriginalSelection] = []) async throws -> SavedContentAnswer {
        try current(p, requestID: p.requestID); try await store.validate(p.permit); try current(p, requestID: p.requestID)
        let byID = Dictionary(uniqueKeysWithValues: selections.map { ($0.recordID, $0) })
        let inheritedUnclear = meaning.operation == .filter ? p.context?.unclearRecordIDs ?? [] : []
        func admittedRelevance(_ selection: SavedContentPageSelection) -> SavedContentRelevance {
            if selection.relevance == .relevant && inheritedUnclear.contains(selection.recordID) { return .unclear }
            return selection.relevance
        }
        let sourceByReference = Dictionary(uniqueKeysWithValues: p.sources.map { ($0.reference, $0) })
        let cards = try rows.compactMap { row -> SavedContentCard? in
            guard let selection = byID[row.projection.recordID], selection.relevance != .notRelevant else { return nil }
            let retained = meaning.operation == .filter ? p.context?.scopedFactIDs[row.projection.recordID] : nil
            let item = try SavedContentPageItem(projection: row.projection, basis: meaning.basis,
                                                retainingFactIDs: retained.map { Set($0) })
            let titles = item.facts.filter { $0.predicate == .name }
            let title = Set(titles.map(\.text)).count == 1 ? titles.first : nil
            let sources = sortedSources(row.projection.sources)
            let readings = try sources.map { reference in
                guard let source = sourceByReference[reference] else { throw MemoryError.staleResult }
                return SavedContentSourceReading(source: reference, assessment: source.readAssessment)
            }
            return SavedContentCard(recordID: row.projection.recordID, recordRevision: row.projection.recordRevision,
                relevance: admittedRelevance(selection), title: title, facts: selection.selectedFacts,
                sources: sources, sourceReadings: readings)
        }
        let scopeSources: [SourceSnapshot]
        if meaning.operation == .filter || meaning.operation == .originals {
            let ids = Set(rows.flatMap { $0.projection.sources }.map(\.id)); scopeSources = p.sources.filter { ids.contains($0.reference.id) }
        } else { scopeSources = p.sources }
        let represented = Set(rows.flatMap { $0.projection.sources })
        let unassessed = scopeSources.filter { $0.readAssessment == nil }
        let withObservedText = unassessed.filter { source in
            source.observations.contains { observation in
                observation.kind == .text && !observation.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        let coverage = SavedContentCoverage(wasExecuted: ![.clarify, .unsupported].contains(meaning.operation), declaredSources: scopeSources.count,
            declaredRecords: meaning.operation == .search ? p.catalog.recordIDs.count : rows.count, visitedRecords: visited,
            unprojectedRecordIDs: meaning.operation == .search ? p.missingRecords : [],
            unreadSources: unassessed.map(\.reference),
            textObservedWithoutAssessment: withObservedText.map(\.reference),
            partialSources: scopeSources.filter { $0.readAssessment?.coverage == .partial }.map(\.reference),
            noReadableDetailsSources: scopeSources.filter { $0.readAssessment?.coverage == .noReadableDetails }.map(\.reference),
            sourcesWithoutProjection: scopeSources.filter { !represented.contains($0.reference) }.map(\.reference),
            pendingSourcePreparations: p.pendingSources.filter { pending in scopeSources.contains { $0.reference == pending } },
            unresolvedRecordIDs: selections.filter { admittedRelevance($0) == .unclear }.map(\.recordID))
        return SavedContentAnswer(requestID: p.requestID, meaning: meaning, cards: cards, originals: originals,
            coverage: coverage, pageReceipts: receipts, prepared: p, examined: rows)
    }

    public func admit(_ answer: SavedContentAnswer, activeRequestID: UUID) async throws -> SavedContentAnswer {
        try current(answer.prepared, requestID: activeRequestID); try await store.validate(answer.prepared.permit)
        try current(answer.prepared, requestID: activeRequestID)
        return answer
    }
    private func proposalSectionFactIDs(question: String, item: SavedContentPageItem,
                                       displayed: [SavedContentTextFact]) -> [String]? {
        let options: String.CompareOptions = [.regularExpression, .caseInsensitive]
        guard item.sources.count == 1,
              question.range(of: #"\bideas?\b"#, options: options) != nil,
              let target = question.range(of: #"\b(?:for|about)\s+[^?!.]+[?!.]?$"#, options: options) else { return nil }
        func subject(_ line: String) -> String? {
            let prefix = #"^(?:(?:ideas|proposals)\s+)?(?:for|about)\s+(?:the\s+|a\s+)?"#
            guard let start = line.range(of: prefix, options: options) else { return nil }
            return line[start.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ":.?! "))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        }
        guard let requested = subject(String(question[target])), !requested.isEmpty else { return nil }
        let displayedIDs = Set(displayed.map(\.id))
        var scope: [String] = []
        var inSection = false
        var displayedBody = false
        for fact in item.facts where fact.isPrintedEvidence {
            if fact.text.trimmingCharacters(in: .whitespaces).hasSuffix(":"), let label = subject(fact.text) {
                inSection = label == requested
            } else if inSection {
                displayedBody = displayedBody || displayedIDs.contains(fact.id)
            }
            if inSection { scope.append(fact.id) }
        }
        // A displayed body fact binds to its observed section even when the
        // answer omitted the section heading from the excerpt.
        guard displayedBody else { return nil }
        let scoped = Set(scope)
        // A displayed supporting sentence outside the labelled section can
        // belong to the same answer. Keep the whole source when that is unclear.
        guard displayed.filter(\.isPrintedEvidence).allSatisfy({ fact in
            scoped.contains(fact.id) || fact.text.range(of: #"[.!?]\s*$"#, options: .regularExpression) == nil
        }) else { return nil }
        let retained = item.facts.filter { fact in
            scoped.contains(fact.id) || (fact.origin == .domainCorrection && displayedIDs.contains(fact.id))
        }.map(\.id)
        return retained.count < item.facts.count ? retained : nil
    }

    public func contextForDisplayedAnswer(_ answer: SavedContentAnswer, orderedRecordIDs: [String],
                                         activeRequestID: UUID, displayIdentity: UUID? = nil) async throws -> SavedContentDisplayedContext {
        guard !busy else { throw SemanticError.existingAttempt }; busy = true; defer { busy = false }
        _ = try await admit(answer, activeRequestID: activeRequestID)
        guard [.search, .filter].contains(answer.meaning.operation), Set(orderedRecordIDs).count == orderedRecordIDs.count,
              Set(orderedRecordIDs).isSubset(of: Set(answer.cards.map(\.recordID))) else { throw MemoryError.invalidContext }
        let byID = Dictionary(uniqueKeysWithValues: answer.examined.map { ($0.projection.recordID, $0) })
        let cards = Dictionary(uniqueKeysWithValues: answer.cards.map { ($0.recordID, $0) })
        let rows = try orderedRecordIDs.map { id -> StoredWorldMemory in
            guard let row = byID[id] else { throw MemoryError.invalidContext }; return row
        }
        var permits: [SourceReadPermit] = []
        for source in sortedSources(Set(rows.flatMap { $0.projection.sources })) {
            let read = try await store.sourceReadSnapshot(sourceID: source.id, permit: answer.prepared.permit)
            guard read.source.reference == source else { throw MemoryError.staleResult }; permits.append(read.permit)
        }
        let unclearRecordIDs = orderedRecordIDs.filter { cards[$0]?.relevance == .unclear }
        var scopedFactIDs: [String: [String]] = [:]
        for row in rows {
            let id = row.projection.recordID
            if answer.meaning.operation == .filter {
                scopedFactIDs[id] = answer.prepared.context?.scopedFactIDs[id]
            } else if let displayed = cards[id]?.facts {
                let item = try SavedContentPageItem(projection: row.projection, basis: answer.meaning.basis)
                scopedFactIDs[id] = proposalSectionFactIDs(question: answer.prepared.question, item: item, displayed: displayed)
            }
        }
        struct Binding: Encodable {
            let contextID, answerRequestID: UUID
            let meaningSHA256: String
            let projections: [WorldMemoryProjection]
            let displayedFactIDs: [[String]]
            let unclearRecordIDs: [String]?
            let scopedFactIDs: [String: [String]]?
        }
        let contextID = displayIdentity ?? UUID()
        let binding = ChoiceTask.hash(try encoded(Binding(contextID: contextID, answerRequestID: answer.requestID,
            meaningSHA256: answer.meaning.receipt.requestSHA256, projections: rows.map(\.projection),
            displayedFactIDs: orderedRecordIDs.map { cards[$0]!.facts.map(\.id) },
            unclearRecordIDs: unclearRecordIDs.isEmpty ? nil : unclearRecordIDs,
            scopedFactIDs: scopedFactIDs.isEmpty ? nil : scopedFactIDs)))
        try current(answer.prepared, requestID: activeRequestID); try await store.validate(answer.prepared.permit)
        let context = SavedContentDisplayedContext(id: contextID, answerRequestID: answer.requestID, bindingSHA256: binding,
            orderedRecordIDs: orderedRecordIDs, owner: identity, catalogID: answer.prepared.catalog.id,
            rows: rows, titles: orderedRecordIDs.map { id in
                let card = cards[id]!
                if let scoped = scopedFactIDs[id], let fact = card.facts.first(where: { scoped.contains($0.id) }) {
                    return fact.text
                }
                return card.title?.text ?? card.facts.first?.text ?? "Unresolved saved text"
            }, unclearRecordIDs: Set(unclearRecordIDs), scopedFactIDs: scopedFactIDs, sourcePermits: permits)
        currentContext = contextID
        return context
    }
}

import Foundation
import IBrain
import IBrainSemantics

public enum SavedContentReplayError: Error, Equatable {
    case invalidEvidence, unauthorized, expiredSession, untrustedReceipt
    case publicationMismatch, taskMismatch, noPendingTask, capacityExceeded
}

/// Scoped, derived evidence only. This is neither an application store nor a
/// processing grant. Capture only the currently permitted model collection.
public struct SavedContentReplaySnapshot: Codable, Equatable, Sendable {
    public let schema: Int
    public let scope: MemoryScope
    public let catalogID: String
    public let sourceIDs: [String]
    public let recordIDs: [String]
    public let sources: [SourceSnapshot]
    public let projections: [WorldMemoryProjection]
    public let pendingSources: [SourceReference]

    public init(scope: MemoryScope, catalog: SavedContentCatalog, sources: [SourceSnapshot],
                projections: [WorldMemoryProjection], pendingSources: [SourceReference] = []) throws {
        schema = 1; self.scope = scope; catalogID = catalog.id
        sourceIDs = catalog.sourceIDs.sorted(); recordIDs = catalog.recordIDs.sorted()
        self.sources = sources.sorted { $0.reference.id < $1.reference.id }
        self.projections = projections.sorted { $0.recordID < $1.recordID }
        self.pendingSources = pendingSources.sorted { $0.id < $1.id }
        try validate()
    }
    public var catalog: SavedContentCatalog {
        .init(id: catalogID, sourceIDs: Set(sourceIDs), recordIDs: Set(recordIDs))
    }
    public func digest() throws -> String { try SavedContentReplay.digest(self) }

    /// Uses the existing store owner and one revalidated snapshot permit.
    /// Unrelated sources/records are not exported. Missing projections stay
    /// declared in recordIDs so replay preserves negative coverage.
    public static func capture(store: MemoryStore, catalog: SavedContentCatalog) async throws -> Self {
        try Task.checkCancellation()
        let permit = try await store.permit()
        let source = try await store.sourceSearchSnapshot(permit: permit)
        let world = try await store.worldSearchSnapshot(permit: permit, maximumEntities: 4096)
        let inventory = try await store.recordInventory(permit: permit)
        let value = try Self(scope: source.scope, catalog: catalog,
            sources: source.sources.filter { catalog.sourceIDs.contains($0.reference.id) },
            projections: world.entities.map(\.projection).filter { catalog.recordIDs.contains($0.recordID) },
            pendingSources: inventory.pendingSourcePreparations.filter { catalog.sourceIDs.contains($0.id) }.map { $0 })
        try await store.validate(permit); try Task.checkCancellation()
        return value
    }
    fileprivate func validate() throws {
        guard schema == 1, !scope.ownerID.isEmpty, !scope.namespace.isEmpty, !catalogID.isEmpty,
              sourceIDs.count <= 16_384, recordIDs.count <= 4096,
              sourceIDs == Set(sourceIDs).sorted(), recordIDs == Set(recordIDs).sorted(),
              sources.map({ $0.reference.id }) == sourceIDs,
              projections.map(\.recordID) == projections.map(\.recordID).sorted(),
              Set(projections.map(\.recordID)).count == projections.count,
              Set(projections.map(\.recordID)).isSubset(of: Set(recordIDs)),
              sources.allSatisfy({ $0.scope == scope }),
              pendingSources.map(\.id) == Set(pendingSources.map(\.id)).sorted() else {
            throw SavedContentReplayError.invalidEvidence
        }
        let refs = Set(sources.map(\.reference))
        guard pendingSources.allSatisfy(refs.contains), projections.allSatisfy({
            $0.scope == scope && $0.kind == .document && !$0.sources.isEmpty && $0.sources.isSubset(of: refs)
        }) else { throw SavedContentReplayError.invalidEvidence }
    }
}

public struct SavedContentReplayQuery: Codable, Equatable, Sendable {
    public let question: String
    public let taskID: String
    public let requestID: UUID
    public let parentContextID: UUID?
    public init(question: String, taskID: String, requestID: UUID, parentContextID: UUID? = nil) {
        self.question = question; self.taskID = taskID; self.requestID = requestID
        self.parentContextID = parentContextID
    }
    public func digest() throws -> String { try SavedContentReplay.digest(self) }
}

/// A description of a genuinely published result, NOT a deserialized context.
/// Pin must authenticate actual publication/order before approving its digest.
public struct SavedContentReplayPublication: Codable, Sendable {
    public let sessionID: UUID
    public let snapshot: SavedContentReplaySnapshot
    public let query: SavedContentReplayQuery
    public let receipts: [DecisionReceipt]
    public let contextID: UUID
    public let bindingSHA256: String
    public let orderedRecordIDs: [String]
    public init(sessionID: UUID, snapshot: SavedContentReplaySnapshot, query: SavedContentReplayQuery,
                receipts: [DecisionReceipt], contextID: UUID, bindingSHA256: String, orderedRecordIDs: [String]) {
        self.sessionID = sessionID; self.snapshot = snapshot; self.query = query; self.receipts = receipts
        self.contextID = contextID; self.bindingSHA256 = bindingSHA256; self.orderedRecordIDs = orderedRecordIDs
    }
    public init(sessionID: UUID, snapshot: SavedContentReplaySnapshot, query: SavedContentReplayQuery,
                answer: SavedContentAnswer, context: SavedContentDisplayedContext) throws {
        guard answer.requestID == query.requestID, context.answerRequestID == query.requestID else {
            throw SavedContentReplayError.invalidEvidence
        }
        self.init(sessionID: sessionID, snapshot: snapshot, query: query,
            receipts: [answer.meaning.receipt] + answer.pageReceipts, contextID: context.id,
            bindingSHA256: context.bindingSHA256, orderedRecordIDs: context.orderedRecordIDs)
    }
}

public struct SavedContentReplayOriginal: Codable, Equatable, Sendable {
    public let source: SourceReference
    public let originalSHA256: String
    public init(source: SourceReference, originalSHA256: String) {
        self.source = source; self.originalSHA256 = originalSHA256
    }
}

public struct SavedContentReplayRequest: Codable, Sendable {
    public let contract: String
    public let sessionID: UUID
    public let privacyScopeSHA256: String
    public let originals: [SavedContentReplayOriginal]
    public let snapshot: SavedContentReplaySnapshot
    public let history: [SavedContentReplayPublication]
    public let query: SavedContentReplayQuery
    /// Already received genuine receipts for THIS query, in exact dispatch order.
    public let receipts: [DecisionReceipt]
    public let expectedTask: ChoiceTask
    public init(sessionID: UUID, privacyScopeSHA256: String, originals: [SavedContentReplayOriginal],
                snapshot: SavedContentReplaySnapshot, history: [SavedContentReplayPublication] = [],
                query: SavedContentReplayQuery, receipts: [DecisionReceipt] = [], expectedTask: ChoiceTask) {
        contract = SavedContentReplay.version; self.sessionID = sessionID; self.privacyScopeSHA256 = privacyScopeSHA256
        self.originals = originals.sorted { $0.source.id < $1.source.id }; self.snapshot = snapshot
        self.history = history; self.query = query; self.receipts = receipts; self.expectedTask = expectedTask
    }
}

/// Host-owned ledger evidence. Never create this from caller-supplied receipts
/// without comparing them with the actual server-retained invocation record.
public struct SavedContentReplayTrustedReceipt: Sendable {
    public let sessionID: UUID
    public let receipt: DecisionReceipt
    public init(sessionID: UUID, receipt: DecisionReceipt) { self.sessionID = sessionID; self.receipt = receipt }
}

/// Deliberately NOT Codable. Construct out of band after Pin's native intent,
/// publication witness, processing consent, source/original allowlist and lease
/// checks. Request JSON and hashes alone never confer these permissions.
public struct SavedContentReplayPolicy: Sendable {
    public let sessionID: UUID
    public let scope: MemoryScope
    public let privacyScopeSHA256: String
    public let currentSnapshotSHA256: String
    public let displayedHistorySHA256: String
    public let currentQuerySHA256: String
    public let originalSHA256BySourceID: [String: String]
    public let receiptProvider: String
    public let receiptModel: String
    public let trustedReceipts: [SavedContentReplayTrustedReceipt]
    public let issuedAt: Date
    public let expiresAt: Date
    public let maximumRequestBytes: Int
    public let maximumPublications: Int
    public let maximumReceiptsPerQuery: Int
    public let maximumRecordsPerPage: Int
    public init(sessionID: UUID, scope: MemoryScope, privacyScopeSHA256: String,
                currentSnapshotSHA256: String, displayedHistorySHA256: String, currentQuerySHA256: String,
                originalSHA256BySourceID: [String: String], receiptProvider: String, receiptModel: String,
                trustedReceipts: [SavedContentReplayTrustedReceipt], issuedAt: Date, expiresAt: Date,
                maximumRequestBytes: Int = 8_388_608, maximumPublications: Int = 8,
                maximumReceiptsPerQuery: Int = 4097, maximumRecordsPerPage: Int = 12) {
        self.sessionID = sessionID; self.scope = scope; self.privacyScopeSHA256 = privacyScopeSHA256
        self.currentSnapshotSHA256 = currentSnapshotSHA256; self.displayedHistorySHA256 = displayedHistorySHA256
        self.currentQuerySHA256 = currentQuerySHA256; self.originalSHA256BySourceID = originalSHA256BySourceID
        self.receiptProvider = receiptProvider; self.receiptModel = receiptModel; self.trustedReceipts = trustedReceipts
        self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.maximumRequestBytes = maximumRequestBytes
        self.maximumPublications = maximumPublications; self.maximumReceiptsPerQuery = maximumReceiptsPerQuery
        self.maximumRecordsPerPage = maximumRecordsPerPage
    }
}

/// A host-local validation result, not a transferable source/display capability.
public struct SavedContentReplayValidation: Sendable {
    public let task: ChoiceTask
    public let requestSHA256: String
    public let sessionBindingSHA256: String
    public let publicationsReplayed: Int
    public let receiptsReplayed: Int
    public var stage: String { task.version == SavedContentQuestionPlanning.meaningVersion ? "meaning" : "evidence" }
    fileprivate init(task: ChoiceTask, requestSHA256: String, sessionBindingSHA256: String,
                     publicationsReplayed: Int, receiptsReplayed: Int) {
        self.task = task; self.requestSHA256 = requestSHA256; self.sessionBindingSHA256 = sessionBindingSHA256
        self.publicationsReplayed = publicationsReplayed; self.receiptsReplayed = receiptsReplayed
    }
}

public enum SavedContentReplay {
    public static let version = "saved-content-replay-v1"
    public static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    public static func digest<T: Encodable>(_ value: T) throws -> String { ChoiceTask.hash(try encoded(value)) }
    public static func historyDigest(_ history: [SavedContentReplayPublication]) throws -> String { try digest(history) }
    private static func validSHA(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    private static func lease(_ policy: SavedContentReplayPolicy, at now: Date) throws {
        guard now.timeIntervalSince1970.isFinite, policy.issuedAt.timeIntervalSince1970.isFinite,
              policy.expiresAt.timeIntervalSince1970.isFinite, policy.issuedAt < policy.expiresAt,
              policy.expiresAt.timeIntervalSince(policy.issuedAt) <= 86_400,
              now >= policy.issuedAt, now < policy.expiresAt else { throw SavedContentReplayError.expiredSession }
    }
    private static func query(_ value: SavedContentReplayQuery) throws {
        guard !value.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.question.utf8.count <= 4096, !value.taskID.isEmpty, value.taskID.utf8.count <= 256 else {
            throw SavedContentReplayError.invalidEvidence
        }
    }
    private static func receipt(_ value: DecisionReceipt, policy: SavedContentReplayPolicy,
                                approved: Set<String>) throws {
        guard value.provider == policy.receiptProvider, value.model == policy.receiptModel,
              value.elapsedSeconds.isFinite, value.elapsedSeconds >= 0,
              approved.contains(try digest(value)) else { throw SavedContentReplayError.untrustedReceipt }
    }
    private static func approvedReceipts(_ policy: SavedContentReplayPolicy) throws -> Set<String> {
        var result = Set<String>(), byRequest: [String: String] = [:]
        for entry in policy.trustedReceipts {
            guard entry.sessionID == policy.sessionID, entry.receipt.provider == policy.receiptProvider,
                  entry.receipt.model == policy.receiptModel, entry.receipt.elapsedSeconds.isFinite,
                  entry.receipt.elapsedSeconds >= 0 else { throw SavedContentReplayError.untrustedReceipt }
            let hash = try digest(entry.receipt)
            if let old = byRequest[entry.receipt.requestSHA256], old != hash { throw SavedContentReplayError.untrustedReceipt }
            byRequest[entry.receipt.requestSHA256] = hash; result.insert(hash)
        }
        return result
    }

    /// Cheap preflight usable on-device before uploading any evidence. The host
    /// must independently construct its policy from authenticated local owners.
    /// This does not replace exact reconstruction or Pin's dispatch/admission gate.
    public static func validateAuthorization(_ request: SavedContentReplayRequest, policy: SavedContentReplayPolicy,
                                              at now: Date = Date()) throws {
        try Task.checkCancellation(); try lease(policy, at: now)
        guard (128...16_777_216).contains(policy.maximumRequestBytes), (1...16).contains(policy.maximumPublications),
              (1...4097).contains(policy.maximumReceiptsPerQuery), (1...128).contains(policy.maximumRecordsPerPage),
              request.history.count <= policy.maximumPublications,
              request.receipts.count <= policy.maximumReceiptsPerQuery,
              try encoded(request).count <= policy.maximumRequestBytes else { throw SavedContentReplayError.capacityExceeded }
        guard request.contract == version, request.sessionID == policy.sessionID,
              request.snapshot.scope == policy.scope, request.privacyScopeSHA256 == policy.privacyScopeSHA256,
              validSHA(policy.privacyScopeSHA256), validSHA(policy.currentSnapshotSHA256),
              validSHA(policy.displayedHistorySHA256), validSHA(policy.currentQuerySHA256),
              !policy.receiptProvider.isEmpty, !policy.receiptModel.isEmpty,
              try request.snapshot.digest() == policy.currentSnapshotSHA256,
              try historyDigest(request.history) == policy.displayedHistorySHA256,
              try request.query.digest() == policy.currentQuerySHA256 else { throw SavedContentReplayError.unauthorized }
        try request.snapshot.validate(); try query(request.query)
        guard request.originals.map({ $0.source.id }) == request.snapshot.sourceIDs,
              request.originals.allSatisfy({ original in
                  request.snapshot.sources.contains { $0.reference == original.source } && validSHA(original.originalSHA256) &&
                  policy.originalSHA256BySourceID[original.source.id] == original.originalSHA256
              }) else { throw SavedContentReplayError.unauthorized }
        let currentSources = Dictionary(uniqueKeysWithValues: request.snapshot.sources.map { ($0.reference.id, $0) })
        let currentRows = Dictionary(uniqueKeysWithValues: request.snapshot.projections.map { ($0.recordID, $0) })
        let approved = try approvedReceipts(policy)
        var previous: UUID?, contexts = Set<UUID>(), operations = Set<UUID>()
        for publication in request.history {
            try publication.snapshot.validate(); try query(publication.query)
            guard publication.sessionID == policy.sessionID, publication.snapshot.scope == policy.scope,
                  publication.snapshot.catalogID == request.snapshot.catalogID,
                  Set(publication.snapshot.recordIDs).isSubset(of: Set(request.snapshot.recordIDs)),
                  publication.snapshot.sources.allSatisfy({ currentSources[$0.reference.id] == $0 }),
                  publication.snapshot.projections.allSatisfy({ currentRows[$0.recordID] == $0 }),
                  publication.query.parentContextID == previous,
                  contexts.insert(publication.contextID).inserted, operations.insert(publication.query.requestID).inserted,
                  validSHA(publication.bindingSHA256), !publication.receipts.isEmpty,
                  publication.receipts.count <= policy.maximumReceiptsPerQuery,
                  Set(publication.orderedRecordIDs).count == publication.orderedRecordIDs.count else {
                throw SavedContentReplayError.publicationMismatch
            }
            for r in publication.receipts { try receipt(r, policy: policy, approved: approved) }
            previous = publication.contextID
        }
        guard request.query.parentContextID == previous, operations.insert(request.query.requestID).inserted else {
            throw SavedContentReplayError.publicationMismatch
        }
        for r in request.receipts { try receipt(r, policy: policy, approved: approved) }
    }

    private static func install(_ snapshot: SavedContentReplaySnapshot, into store: MemoryStore) async throws {
        let records = snapshot.projections.map { DomainRecordPin(id: $0.recordID, revision: $0.recordRevision,
            sources: $0.sources, recordKind: .worldEntity) }
        let permit = try await store.synchronize(.init(sources: snapshot.sources, records: records,
            pendingSourcePreparations: Set(snapshot.pendingSources)))
        _ = try await store.applyWorldBatch(snapshot.projections.map { WorldMemoryWrite($0) }, permit: permit)
    }
    private static func parent(_ query: SavedContentReplayQuery, current: SavedContentDisplayedContext?) throws -> SavedContentDisplayedContext? {
        if let id = query.parentContextID {
            guard let current, current.id == id else { throw SavedContentReplayError.publicationMismatch }
            return current
        }
        guard current == nil else { throw SavedContentReplayError.publicationMismatch }
        return nil
    }
    private static func replay(_ receipts: [DecisionReceipt], prepared: PreparedSavedContentQuestion,
                               engine: SavedContentQuestionSession) async throws -> SavedContentProgress {
        guard let first = receipts.first else { throw SavedContentReplayError.invalidEvidence }
        var result = try await engine.start(first, for: prepared, activeRequestID: prepared.requestID)
        for receipt in receipts.dropFirst() {
            guard result.nextTask != nil else { throw SavedContentReplayError.noPendingTask }
            try await engine.validatePendingPage(activeRequestID: prepared.requestID)
            result = try await engine.advance(receipt, activeRequestID: prepared.requestID)
        }
        return result
    }

    /// No provider calls. Uses a new disposable store, never the app's shared
    /// cache. Dispatch ONLY the returned reconstructed task, not caller bytes.
    /// Recheck Pin's actual lease/access/cancellation immediately at dispatch.
    public static func reconstruct(_ request: SavedContentReplayRequest, policy: SavedContentReplayPolicy,
                                   scratchParent: URL, clock: @Sendable () -> Date = { Date() }) async throws -> SavedContentReplayValidation {
        try validateAuthorization(request, policy: policy, at: clock())
        let directory = scratchParent.appendingPathComponent("saved-content-replay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let store: MemoryStore
        do { store = try MemoryStore(directory: directory, scope: policy.scope) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        do {
            let engine = try SavedContentQuestionSession(store: store,
                budget: .init(maximumRecordsPerPage: policy.maximumRecordsPerPage))
            var context: SavedContentDisplayedContext?, count = 0
            for publication in request.history {
                try Task.checkCancellation(); try lease(policy, at: clock())
                try await install(publication.snapshot, into: store)
                let p = try await engine.prepare(question: publication.query.question, taskID: publication.query.taskID,
                    requestID: publication.query.requestID, catalog: publication.snapshot.catalog,
                    context: try parent(publication.query, current: context))
                try await engine.validatePrepared(p, activeRequestID: p.requestID)
                let result = try await replay(publication.receipts, prepared: p, engine: engine)
                guard let value = result.answer, result.nextTask == nil else { throw SavedContentReplayError.publicationMismatch }
                let answer = try await engine.admit(value, activeRequestID: p.requestID)
                let rebuilt = try await engine.contextForDisplayedAnswer(answer, orderedRecordIDs: publication.orderedRecordIDs,
                    activeRequestID: p.requestID, displayIdentity: publication.contextID)
                guard rebuilt.bindingSHA256 == publication.bindingSHA256,
                      rebuilt.orderedRecordIDs == publication.orderedRecordIDs else { throw SavedContentReplayError.publicationMismatch }
                context = rebuilt; count += publication.receipts.count
            }
            try await install(request.snapshot, into: store)
            let prepared = try await engine.prepare(question: request.query.question, taskID: request.query.taskID,
                requestID: request.query.requestID, catalog: request.snapshot.catalog,
                context: try parent(request.query, current: context))
            try await engine.validatePrepared(prepared, activeRequestID: prepared.requestID)
            let task: ChoiceTask
            if request.receipts.isEmpty { task = prepared.task }
            else {
                let result = try await replay(request.receipts, prepared: prepared, engine: engine)
                guard let next = result.nextTask, result.answer == nil else { throw SavedContentReplayError.noPendingTask }
                try await engine.validatePendingPage(activeRequestID: prepared.requestID); task = next
            }
            guard try encoded(task) == encoded(request.expectedTask) else { throw SavedContentReplayError.taskMismatch }
            try Task.checkCancellation(); try lease(policy, at: clock())
            struct Binding: Encodable {
                let contract: String; let sessionID: UUID; let privacyScopeSHA256, requestEvidenceSHA256, taskSHA256: String
            }
            let binding = try digest(Binding(contract: version, sessionID: request.sessionID,
                privacyScopeSHA256: request.privacyScopeSHA256, requestEvidenceSHA256: digest(request), taskSHA256: digest(task)))
            let value = SavedContentReplayValidation(task: task, requestSHA256: try task.digest(),
                sessionBindingSHA256: binding, publicationsReplayed: request.history.count,
                receiptsReplayed: count + request.receipts.count)
            await store.close(); try FileManager.default.removeItem(at: directory)
            try Task.checkCancellation(); try lease(policy, at: clock())
            return value
        } catch {
            await store.close(); try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

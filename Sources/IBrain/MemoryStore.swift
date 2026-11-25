import Foundation
import CryptoKit

/// Serializes local projection writes and bounded result checks. The host must
/// deliver authority invalidation before publishing across its own boundary.
public actor MemoryStore {
    public let scope: MemoryScope
    private let session = UUID()
    private let file: AtomicFile
    private var state: DiskState
    private var catalog: Catalog?
    private var catalogEpoch: UInt64 = 0
    private var sourceIncarnations: [String: UUID] = [:]
    private var isClosed = false

    private struct Catalog: Equatable {
        var sources: [String: SourceSnapshot]
        var records: [String: DomainRecordPin]
        var pendingSourcePreparations: Set<SourceReference>
    }

    public init(directory: URL, scope: MemoryScope) throws {
        guard !scope.ownerID.isEmpty, !scope.namespace.isEmpty else { throw MemoryError.scopeMismatch }
        self.scope = scope
        let opened = try AtomicFile(directory: directory)
        if let data = try opened.read() {
            let decoded: DiskState
            do { decoded = try JSONDecoder().decode(DiskState.self, from: data) }
            catch { throw MemoryError.corruptStore }
            guard (1...4).contains(decoded.schema) else { throw MemoryError.unsupportedSchema }
            guard decoded.scope == scope else { throw MemoryError.scopeMismatch }
            state = decoded
        } else { state = DiskState(scope: scope) }
        file = opened
    }

    public func close() { catalog = nil; sourceIncarnations = [:]; isClosed = true; file.close() }

    /// A complete authoritative snapshot, not a partial page of sources.
    /// Identical repeated rows collapse; conflicting metadata fails closed.
    @discardableResult
    public func synchronize(_ snapshot: AuthoritySnapshot) throws -> SnapshotPermit {
        try checkOpen()
        var sources: [String: SourceSnapshot] = [:]
        var records: [String: DomainRecordPin] = [:]
        do {
            for source in snapshot.sources {
                guard source.scope == scope else { throw MemoryError.scopeMismatch }
                try source.readAssessment?.validate(source: source.reference, observations: source.observations)
                guard !source.reference.id.isEmpty, source.reference.revision > 0, !source.reference.fingerprint.isEmpty,
                      Set(source.observations.map(\.id)).count == source.observations.count,
                      source.observations.allSatisfy({ !$0.id.isEmpty && !$0.value.isEmpty }),
                      sources[source.reference.id].map({ $0 == source }) ?? true else { throw MemoryError.invalidSnapshot }
                if let provenance=source.readingProvenance{
                    guard Set(provenance.keys)==Set(source.observations.map(\.id)),provenance.values.allSatisfy({p in p.sourceAtRead.id==source.reference.id && p.sourceAtRead.fingerprint==source.reference.fingerprint && p.sourceAtRead.revision>0 && p.sourceAtRead.revision<=source.reference.revision && p.receiptSHA256.count==64 && p.receiptSHA256.allSatisfy{"0123456789abcdef".contains($0)}})else{throw MemoryError.invalidSnapshot}
                }
                sources[source.reference.id] = source
            }
            guard snapshot.pendingSourcePreparations.allSatisfy({ sources[$0.id]?.reference == $0 }) else { throw MemoryError.invalidSnapshot }
            for record in snapshot.records {
                guard !record.id.isEmpty, record.revision > 0,
                      record.revision >= (state.recordRevisions[record.id] ?? 0), !record.sources.isEmpty,
                      state.recordRevisions[record.id] == nil || record.effectiveKind == (state.recordKinds?[record.id] ?? .appointment),
                      record.sources.allSatisfy({ sources[$0.id]?.reference == $0 }),
                      records[record.id].map({ $0 == record }) ?? true else { throw MemoryError.invalidSnapshot }
                records[record.id] = record
            }
        } catch {
            // An invalid new authority read cannot leave the prior grant live.
            catalog = nil; sourceIncarnations = [:]; catalogEpoch += 1; throw error
        }
        sources = sources.filter { !state.forgottenSources.contains($0.key) }
        records = records.filter { $0.value.sources.allSatisfy { sources[$0.id]?.reference == $0 } }
        let pending = snapshot.pendingSourcePreparations.filter { sources[$0.id]?.reference == $0 }
        let nextCatalog = Catalog(sources: sources, records: records, pendingSourcePreparations: pending)
        if catalog != nextCatalog {
            let nextIncarnations = sourceIncarnations(for: nextCatalog)
            var next = state
            next.rows = next.rows.filter { isCurrent($0.value.projection, in: nextCatalog) }
            next.sourceChanges=next.sourceChanges?.filter {isChangeCurrent($0.value,in:nextCatalog)}
            next.worldRows = next.worldRows?.filter { isWorldCurrent($0.value.projection, in: nextCatalog) }
            next.generation += 1
            do { try commit(next) }
            catch { catalog = nil; sourceIncarnations = [:]; catalogEpoch += 1; throw error }
            catalog = nextCatalog; sourceIncarnations = nextIncarnations; catalogEpoch += 1
        }
        return try permit()
    }

    public func permit() throws -> SnapshotPermit {
        try checkOpen(); guard catalog != nil else { throw MemoryError.needsSynchronization }
        return SnapshotPermit(session: session, generation: state.generation, catalogEpoch: catalogEpoch)
    }

    /// Bounded recheck after an asynchronous interpreter, before the host's
    /// domain writer/admission step. This grants no effect authority.
    public func validate(_ permit: SnapshotPermit) throws { try check(permit) }

    /// Does not grant writes or a whole-world snapshot. Native identity changes
    /// tied to this photo revoke the permit even if its pixels are unchanged.
    public func sourceReadSnapshot(sourceID: String, permit: SnapshotPermit) throws -> SourceReadSnapshot {
        try check(permit)
        guard let source = catalog?.sources[sourceID], let incarnation = sourceIncarnations[sourceID] else { throw MemoryError.invalidEvidence }
        return SourceReadSnapshot(source: source, permit: SourceReadPermit(session: session, sourceID: sourceID, incarnation: incarnation))
    }
    public func validate(_ permit: SourceReadPermit) throws {
        try checkOpen(); guard catalog != nil else { throw MemoryError.needsSynchronization }
        guard permit.session == session, catalog?.sources[permit.sourceID] != nil,
              sourceIncarnations[permit.sourceID] == permit.incarnation else { throw MemoryError.stalePermit }
    }

    /// Called by the trusted native owner only AFTER its immutable-byte fetch
    /// and native identity/access/currentness checks. Does not alter a source,
    /// authorize network use or certify that PhotoKit actually supplied bytes.
    public func bindSourceImage(_ read:SourceReadSnapshot,imageSHA256:String,acquisitionID:UUID)throws->SourceImageBinding {
        try validate(read.permit)
        guard catalog?.sources[read.source.reference.id]==read.source,read.source.scope==scope,
              imageSHA256.count==64,imageSHA256.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)})else{throw MemoryError.invalidEvidence}
        // Existing SHA-shaped fingerprints retain their byte-identity meaning;
        // opt-in metadata binding cannot contradict that original proof.
        let fingerprint=read.source.reference.fingerprint.lowercased()
        let isByteDigest=fingerprint.count==64 && fingerprint.utf8.allSatisfy{(48...57).contains($0) || (97...102).contains($0)}
        guard !isByteDigest || fingerprint==imageSHA256 else{throw MemoryError.invalidEvidence}
        return SourceImageBinding(source:read.source,imageSHA256:imageSHA256,acquisitionID:acquisitionID,permit:read.permit)
    }
    public func validate(_ binding:SourceImageBinding)throws {
        try validate(binding.permit)
        guard binding.source.scope==scope,catalog?.sources[binding.source.reference.id]==binding.source else{throw MemoryError.stalePermit}
    }

    private func sourceIncarnations(for next: Catalog) -> [String: UUID] {
        guard let catalog else { return Dictionary(uniqueKeysWithValues: next.sources.keys.map { ($0, UUID()) }) }
        var changed = Set(catalog.sources.keys).union(next.sources.keys).filter { catalog.sources[$0] != next.sources[$0] }
        changed.formUnion(catalog.pendingSourcePreparations.symmetricDifference(next.pendingSourcePreparations).map(\.id))
        for id in Set(catalog.records.keys).union(next.records.keys) where catalog.records[id] != next.records[id] {
            changed.formUnion(catalog.records[id]?.sources.map(\.id) ?? [])
            changed.formUnion(next.records[id]?.sources.map(\.id) ?? [])
        }
        return Dictionary(uniqueKeysWithValues: next.sources.keys.map { id in
            (id, changed.contains(id) ? UUID() : sourceIncarnations[id] ?? UUID())
        })
    }

    /// An exact current source read for optional candidate ranking. It carries
    /// the same global permit through asynchronous encoding and publication.
    public func sourceSearchSnapshot(permit: SnapshotPermit) throws -> SourceSearchSnapshot {
        try check(permit)
        return SourceSearchSnapshot(scope: scope, sources: catalog!.sources.values.sorted {
            $0.reference.id < $1.reference.id
        }, permit: permit)
    }

    /// Does not silently omit cancelled/partial records or truncate candidates.
    /// Existing exact recall remains unchanged. The host must recheck the
    /// original permit after interpretation and before final publication.
    public func recordSearchSnapshot(permit: SnapshotPermit, maximumRecords: Int = 64) throws -> RecordSearchSnapshot {
        try check(permit)
        guard (1...256).contains(maximumRecords), state.rows.count <= maximumRecords else {
            throw MemoryError.unsupportedQuery
        }
        return RecordSearchSnapshot(scope: scope, records: state.rows.values.sorted {
            $0.projection.recordID < $1.projection.recordID
        }, permit: permit)
    }

    /// Exact host-selected canonical IDs, never a lexical/model identity guess.
    /// Unrelated inventory does not consume this bounded context. Missing or
    /// withdrawn selections fail rather than silently shrinking the result.
    public func recordSearchSnapshot(permit: SnapshotPermit, recordIDs: Set<String>, maximumRecords: Int = 256) throws -> RecordSearchSnapshot {
        try check(permit)
        guard (1...256).contains(maximumRecords), !recordIDs.isEmpty, recordIDs.count <= maximumRecords else { throw MemoryError.unsupportedQuery }
        let records = try recordIDs.sorted().map { id in
            guard let row = state.rows[id] else { throw MemoryError.staleResult }
            return row
        }
        return RecordSearchSnapshot(scope: scope, records: records, permit: permit)
    }

    /// Exact canonical linkage over the admitted store, before model context is built.
    public func recordsSupportedBy(_ sources:Set<SourceReference>,permit:SnapshotPermit,maximumRecords:Int=256)throws->SourceRecordSelection {
        try check(permit)
        guard (1...256).contains(maximumRecords),sources.count<=12 else{throw MemoryError.unsupportedQuery}
        guard sources.allSatisfy({catalog!.sources[$0.id]?.reference==$0})else{throw MemoryError.staleResult}
        var ids:Set<String>=[],linked:Set<SourceReference>=[]
        for row in state.rows.values {
            let intersection=row.projection.sources.intersection(sources)
            if !intersection.isEmpty {
                ids.insert(row.projection.recordID);linked.formUnion(intersection)
                guard ids.count<=maximumRecords else{throw MemoryError.unsupportedQuery}
            }
        }
        return SourceRecordSelection(recordIDs:ids,unlinkedSources:sources.subtracting(linked),admittedRecordCount:state.rows.count)
    }

    /// Full canonical identity inventory, never ranked/truncated. Page bodies
    /// remain bounded and all pages must retain this original permit.
    public func recordInventory(permit:SnapshotPermit)throws->RecordInventory {
        try check(permit)
        let linked=Set(state.rows.values.flatMap{$0.projection.sources})
        return RecordInventory(recordIDs:state.rows.keys.sorted(),unprojectedRecordIDs:Set(catalog!.records.keys).subtracting(state.rows.keys),unlinkedSources:Set(catalog!.sources.values.map(\.reference)).subtracting(linked),pendingSourcePreparations:catalog!.pendingSourcePreparations,sourceReadings:catalog!.sources.values.sorted{$0.reference.id<$1.reference.id}.map{WorldSourceReading(source:$0.reference,assessment:$0.readAssessment)},permit:permit)
    }

    /// Recovery after a committed invalidation but interrupted replacement.
    /// Returns only the last local revision, never inaccessible old field values.
    public func lastMemoryRevision(recordID: String, permit: SnapshotPermit) throws -> UInt64? {
        try check(permit)
        guard !state.withdrawnRecords.contains(recordID) else { throw MemoryError.withdrawn }
        guard catalog?.records[recordID] != nil else { throw MemoryError.unvalidatedRecord }
        return state.memoryRevisions[recordID]
    }

    /// Initial insertion or exact idempotent replay. Changed semantics require
    /// a greater native record revision and the explicit supersede operation.
    @discardableResult
    public func upsert(_ projection: MemoryProjection, permit: SnapshotPermit) throws -> StoredMemory {
        try check(permit)
        if let previous = state.recordRevisions[projection.recordID], previous != projection.recordRevision {
            throw MemoryError.staleCorrection
        }
        return try put(projection)
    }

    /// Atomically inserts or exactly replays a set of sibling projections.
    /// Every proposal is validated against the same current authority before
    /// one snapshot commit. A failure publishes none of the new rows. Changed
    /// native record revisions still require explicit CAS supersession.
    /// Returns unique record IDs in canonical order; duplicate identical input
    /// rows collapse. Newly inserted rows share this commit's local revision.
    @discardableResult
    public func upsertBatch(_ projections: [MemoryProjection], permit: SnapshotPermit) throws -> [StoredMemory] {
        try applyBatch(projections.map(ProjectionMutation.insertOrReplay), permit: permit)
    }

    /// Supports a photo update that inserts new objects while CAS-replacing
    /// existing siblings, without exposing the intermediate combinations.
    @discardableResult
    public func applyBatch(_ changes: [ProjectionMutation], permit: SnapshotPermit) throws -> [StoredMemory] {
        try check(permit)
        var unique: [String: ProjectionMutation] = [:]
        for change in changes {
            let id = change.projection.recordID
            if let other = unique[id], other != change { throw MemoryError.conflictingProjection }
            unique[id] = change
        }
        var prepared: [(StoredMemory, String)] = []
        for id in unique.keys.sorted() {
            let change = unique[id]!, projection = change.projection
            switch change {
            case .insertOrReplay:
                if let previous = state.recordRevisions[id], previous != projection.recordRevision { throw MemoryError.staleCorrection }
            case .supersede(let update):
                guard state.memoryRevisions[id] == update.expectedMemoryRevision,
                      let previous = state.recordRevisions[id], projection.recordRevision > previous else { throw MemoryError.staleCorrection }
            }
            prepared.append(try prepare(projection, revision: state.generation + 1))
        }
        guard prepared.contains(where: { state.rows[$0.0.projection.recordID] != $0.0 }) else { return prepared.map(\.0) }
        var next = state; next.generation += 1
        for (row, digest) in prepared { install(row, digest: digest, into: &next) }
        try commit(next)
        return prepared.map(\.0)
    }

    @discardableResult
    public func supersede(_ projection: MemoryProjection, expectedMemoryRevision: UInt64,
                          permit: SnapshotPermit) throws -> StoredMemory {
        try check(permit)
        guard state.memoryRevisions[projection.recordID] == expectedMemoryRevision,
              let previous = state.recordRevisions[projection.recordID], projection.recordRevision > previous else { throw MemoryError.staleCorrection }
        return try put(projection)
    }

    /// CAS-checks every replacement before publishing one complete snapshot.
    /// A stale expected revision or invalid sibling leaves all rows unchanged.
    @discardableResult
    public func supersedeBatch(_ replacements: [ProjectionReplacement], permit: SnapshotPermit) throws -> [StoredMemory] {
        try applyBatch(replacements.map(ProjectionMutation.supersede), permit: permit)
    }

    /// Reconciles a COMPLETE projection set from CURRENT host domain records.
    /// This is cache maintenance, not model/domain admission or a reset. The
    /// current global permit binds all cached CAS checkpoints. Durable user
    /// withdrawals/forgetting are retained even if the host resupplies them.
    /// Missing active records, stale evidence or same-version changed content
    /// refuse the entire rebuild; known newer native revisions use atomic CAS.
    @discardableResult
    public func rebuild(from projections: [MemoryProjection], permit: SnapshotPermit) throws -> ProjectionRebuildReport {
        try check(permit)
        var unique: [String: MemoryProjection] = [:]
        for projection in projections {
            guard projection.scope == scope else { throw MemoryError.scopeMismatch }
            if let other = unique[projection.recordID], other != projection { throw MemoryError.conflictingProjection }
            unique[projection.recordID] = projection
        }
        var active: [MemoryProjection] = [], skipped: [ProjectionRebuildSkip] = []
        for id in unique.keys.sorted() {
            let projection = unique[id]!
            if state.withdrawnRecords.contains(id) {
                skipped.append(ProjectionRebuildSkip(recordID: id, reason: .withdrawnRecord)); continue
            }
            if projection.sources.contains(where: { state.forgottenSources.contains($0.id) }) {
                skipped.append(ProjectionRebuildSkip(recordID: id, reason: .forgottenSource)); continue
            }
            try validate(projection)
            active.append(projection)
        }
        let expected = Set(catalog!.records.values.filter { $0.effectiveKind == .appointment }.map(\.id)).subtracting(state.withdrawnRecords)
        guard Set(active.map(\.recordID)) == expected else { throw MemoryError.incompleteRebuild }
        let changes = try active.map { projection -> ProjectionMutation in
            if let previous = state.recordRevisions[projection.recordID], projection.recordRevision > previous {
                guard let memoryRevision = state.memoryRevisions[projection.recordID] else { throw MemoryError.corruptStore }
                return .supersede(ProjectionReplacement(projection: projection, expectedMemoryRevision: memoryRevision))
            }
            return .insertOrReplay(projection)
        }
        let rows = try applyBatch(changes, permit: permit)
        return ProjectionRebuildReport(rows: rows, skipped: skipped)
    }

    public func withdraw(recordID: String, permit: SnapshotPermit) throws {
        try check(permit)
        guard state.recordRevisions[recordID] != nil else { throw MemoryError.unvalidatedRecord }
        var next = state; next.rows.removeValue(forKey: recordID)
        next.worldRows?.removeValue(forKey: recordID)
        next.sourceChanges?.removeValue(forKey:recordID)
        next.withdrawnRecords.insert(recordID); next.generation += 1; try commit(next)
        for source in catalog?.records[recordID]?.sources ?? [] { sourceIncarnations[source.id] = UUID() }
    }

    /// Access removal prunes the projection and ends the current catalog grant.
    /// Forgetting also persists a source-ID tombstone, blocking re-ingestion.
    public func invalidateSource(id: String, forget: Bool = false) throws {
        try checkOpen()
        var next = state
        next.rows = next.rows.filter { !$0.value.projection.sources.contains(where: { $0.id == id }) }
        next.worldRows = next.worldRows?.filter { !$0.value.projection.sources.contains(where: { $0.id == id }) }
        next.sourceChanges=next.sourceChanges?.filter{!$0.value.sources.contains(where:{$0.id==id})}
        if forget { next.forgottenSources.insert(id) }
        next.generation += 1; try commit(next)
        catalog = nil; sourceIncarnations = [:]; catalogEpoch += 1
    }

    public func retrieve(_ query: RecallQuery, requestID: UUID, now: Date, calendar: Calendar,
                         permit: SnapshotPermit, coverage: RecallCoverage = .unknown) throws -> PreparedAnswer {
        try check(permit)
        guard query.selection != .unsupported else { throw MemoryError.unsupportedQuery }
        let window = try NativeDates.window(query.period, now: now, calendar: calendar)
        var matches: [DatedMatch] = [], uncertain: [UncertainMatch] = []
        for row in state.rows.values {
            let projection = row.projection, appointment = projection.appointment
            guard appointment.status == .scheduled,
                  query.selection != .eventTickets || appointment.kind == .eventTicket else { continue }
            switch NativeDates.resolve(appointment.date, inferredPolicy: query.inferredDatePolicy) {
            case .instant(let date): if window.contains(date) { matches.append(DatedMatch(memory: row, date: date)) }
            case .uncertain(let reason): uncertain.append(UncertainMatch(memory: row, reason: reason))
            }
        }
        matches.sort {
            $0.date == $1.date ? $0.memory.projection.recordID < $1.memory.projection.recordID : $0.date < $1.date
        }
        uncertain.sort { $0.memory.projection.recordID < $1.memory.projection.recordID }
        return PreparedAnswer(requestID: requestID, matches: matches, uncertain: uncertain, window: window, coverage: coverage,
                              permit: permit, query: query, submittedAt: now, calendar: calendar)
    }

    /// Call at the last bounded host publication step, after any asynchronous
    /// model work. No lock is held across model inference by this actor.
    @discardableResult
    public func admit(_ answer: PreparedAnswer, activeRequestID: UUID, now: Date, calendar: Calendar) throws -> PreparedAnswer {
        do { try check(answer.permit) } catch { throw MemoryError.staleResult }
        let sameTime: Bool
        if answer.query.period == .nextSevenDays {
            sameTime = calendar.isDate(now, inSameDayAs: answer.submittedAt)
        } else {
            sameTime = answer.window == (try NativeDates.window(answer.query.period, now: now, calendar: calendar))
        }
        guard answer.requestID == activeRequestID, answer.calendar == calendar, sameTime else { throw MemoryError.staleResult }
        return answer
    }

    public func bind(_ answer: PreparedAnswer, activeRequestID: UUID, now: Date, calendar: Calendar) throws -> ResultContext {
        try admit(answer, activeRequestID: activeRequestID, now: now, calendar: calendar)
        return ResultContext(answerID: answer.requestID,
                             summary: ConversationSummary(period: answer.query.period, orderedTitles: answer.matches.map { $0.memory.projection.appointment.title }),
                             prepared: answer, ordered: answer.matches.map(\.memory), limitsToDisplayed: false)
    }

    /// Bind the exact order actually displayed by the host, including supported
    /// partial appointments. IDs must come from this admitted answer; no facts,
    /// date resolution, coverage or permissions are added by presentation.
    public func bindDisplayed(_ answer: PreparedAnswer, orderedRecordIDs: [String], activeRequestID: UUID,
                              now: Date, calendar: Calendar) throws -> ResultContext {
        try admit(answer, activeRequestID: activeRequestID, now: now, calendar: calendar)
        guard Set(orderedRecordIDs).count == orderedRecordIDs.count else { throw MemoryError.invalidContext }
        let available = Dictionary(uniqueKeysWithValues: (answer.matches.map(\.memory) + answer.uncertain.map(\.memory)).map { ($0.projection.recordID, $0) })
        let ordered = try orderedRecordIDs.map { id in
            guard let row = available[id], state.rows[id] == row else { throw MemoryError.invalidContext }
            return row
        }
        let issues = Dictionary(uniqueKeysWithValues: answer.uncertain.map { ($0.memory.projection.recordID, $0.reason) })
        return ResultContext(answerID: answer.requestID,
            summary: ConversationSummary(period: answer.query.period, orderedTitles: ordered.map { $0.projection.appointment.title },
                                         orderedDateIssues: ordered.map { issues[$0.projection.recordID] }),
            prepared: answer, ordered: ordered, limitsToDisplayed: true)
    }

    /// Contextual selection preserves the prior exact window (including a
    /// rolling window's anchor). A model-visible summary alone is insufficient.
    public func refine(selection: QuerySelection, context: ResultContext, activeAnswerID: UUID, requestID: UUID,
                       now: Date, calendar: Calendar, permit: SnapshotPermit) throws -> PreparedAnswer {
        guard activeAnswerID == context.answerID else { throw MemoryError.invalidContext }
        try admit(context.prepared, activeRequestID: activeAnswerID, now: now, calendar: calendar)
        let result = try retrieve(RecallQuery(period: context.prepared.query.period, selection: selection, inferredDatePolicy: context.prepared.query.inferredDatePolicy), requestID: requestID,
                            now: context.prepared.submittedAt, calendar: calendar, permit: permit, coverage: context.prepared.coverage)
        guard context.limitsToDisplayed else { return result }
        let displayed = Set(context.ordered.map { $0.projection.recordID })
        return PreparedAnswer(requestID: result.requestID,
            matches: result.matches.filter { displayed.contains($0.memory.projection.recordID) },
            uncertain: result.uncertain.filter { displayed.contains($0.memory.projection.recordID) },
            window: result.window, coverage: result.coverage, permit: result.permit, query: result.query,
            submittedAt: result.submittedAt, calendar: result.calendar)
    }

    public func location(ordinal: Int, context: ResultContext, activeAnswerID: UUID, now: Date, calendar: Calendar) throws -> LocationAnswer {
        guard activeAnswerID == context.answerID else { throw MemoryError.invalidContext }
        try admit(context.prepared, activeRequestID: activeAnswerID, now: now, calendar: calendar)
        guard ordinal > 0, ordinal <= context.ordered.count else { throw MemoryError.invalidOrdinal }
        let selected = context.ordered[ordinal - 1]
        guard state.rows[selected.projection.recordID] == selected else { throw MemoryError.staleResult }
        return LocationAnswer(recordID: selected.projection.recordID, venue: selected.projection.appointment.displayVenue,
                              originalSources: selected.projection.sources)
    }

    /// Capture the prior current record before the host changes its domain
    /// pin. The token is scoped to this store session, never model-provided.
    public func captureRevision(recordID:String,permit:SnapshotPermit)throws->CapturedRecordRevision {
        try check(permit)
        guard let row=state.rows[recordID],isCurrent(row.projection,in:catalog!)else{throw MemoryError.unvalidatedRecord}
        return CapturedRecordRevision(session:session,row:row)
    }
    /// Explicitly preserve one latest comparison after a host CAS/rebuild.
    /// Old sources must still be current, e.g. two separate accessible photos.
    @discardableResult public func recordSourceChange(from previous:CapturedRecordRevision,recordID:String,permit:SnapshotPermit)throws->SourceRecordChange {
        try check(permit)
        guard previous.session==session,previous.row.projection.recordID==recordID,let current=state.rows[recordID],previous.row.projection.recordRevision<current.projection.recordRevision else{throw MemoryError.staleCorrection}
        let change=SourceRecordChange(previous:previous.row.projection,current:current.projection)
        guard isChangeCurrent(change,in:catalog!)else{throw MemoryError.invalidEvidence}
        var next=state;var changes=next.sourceChanges ?? [:];changes[recordID]=change
        guard changes.count<=256 else{throw MemoryError.unsupportedQuery}
        next.sourceChanges=changes;next.schema=max(next.schema,2);next.generation += 1;try commit(next);return change
    }
    /// Atomic cache replacement plus comparison publication. The owning
    /// host has already supplied the newer domain pin/current source snapshot.
    @discardableResult public func supersedeWithSourceChange(_ projection:MemoryProjection,from previous:CapturedRecordRevision,permit:SnapshotPermit)throws->SourceRecordChange {
        try check(permit)
        guard previous.session==session,previous.row.projection.recordID==projection.recordID,previous.row.revision==state.memoryRevisions[projection.recordID],previous.row.projection.recordRevision==state.recordRevisions[projection.recordID],projection.recordRevision>previous.row.projection.recordRevision else{throw MemoryError.staleCorrection}
        let (row,digest)=try prepare(projection,revision:state.generation+1)
        let change=SourceRecordChange(previous:previous.row.projection,current:projection)
        guard isChangeCurrent(change,in:catalog!)else{throw MemoryError.invalidEvidence}
        var next=state;next.generation += 1;install(row,digest:digest,into:&next)
        var changes=next.sourceChanges ?? [:];changes[projection.recordID]=change
        guard changes.count<=256 else{throw MemoryError.unsupportedQuery}
        next.sourceChanges=changes;next.schema=max(next.schema,2);try commit(next);return change
    }
    public func sourceChangeSnapshot(permit:SnapshotPermit)throws->[SourceRecordChange] {
        try check(permit)
        return try (state.sourceChanges ?? [:]).values.sorted{$0.recordID<$1.recordID}.map{change in
            guard state.rows[change.recordID]?.projection==change.current,isChangeCurrent(change,in:catalog!)else{throw MemoryError.staleResult};return change
        }
    }
    private func isChangeCurrent(_ change:SourceRecordChange,in catalog:Catalog)->Bool {
        guard change.previous.scope == scope, change.previous.recordID == change.current.recordID,
              change.previous.recordRevision < change.current.recordRevision,
              isCurrent(change.current, in: catalog) else { return false }
        return appointmentDateIsCurrent(change.previous, in: catalog) && appointmentAnchorsAreCurrent(change.previous, in: catalog)
    }

    /// All entities share the existing source authority and atomic file. Mixed
    /// appointments/world pins are explicit; IDs cannot change record family.
    public func worldSearchSnapshot(permit: SnapshotPermit, maximumEntities: Int = 256) throws -> WorldSearchSnapshot {
        try check(permit)
        let rows = state.worldRows ?? [:]
        guard (1...4096).contains(maximumEntities), rows.count <= maximumEntities else { throw MemoryError.unsupportedQuery }
        return WorldSearchSnapshot(scope: scope, entities: rows.values.sorted { $0.projection.recordID < $1.projection.recordID }, permit: permit)
    }

    /// Bounded metadata reads for existing host-owned IDs only. No lexical
    /// matching or relationship creation takes place at this boundary.
    public func linkedWorldHeaders(recordIDs:Set<String>,permit:SnapshotPermit)throws->[LinkedWorldHeader] {
        try check(permit)
        guard recordIDs.count<=128 else{throw MemoryError.unsupportedQuery}
        let rows=state.worldRows ?? [:]
        return try recordIDs.sorted().compactMap{id in
            guard let row=rows[id]else{return nil}
            guard isWorldCurrent(row.projection,in:catalog!)else{throw MemoryError.staleResult}
            let p=row.projection
            let identifying=p.claims.filter{[WorldPredicate.name,.alias,.identifier].contains($0.predicate) && $0.origin != .inferred}
            let names=identifying.compactMap{if case .text(let s)=$0.value{return s};return nil}
            return LinkedWorldHeader(recordID:p.recordID,recordRevision:p.recordRevision,kind:p.kind,identifyingTexts:names,identifyingClaims:identifying,
                sources:p.sources.sorted{($0.id,$0.revision,$0.fingerprint)<($1.id,$1.revision,$1.fingerprint)})
        }
    }
    /// Expand selected fields using the SAME native field/uncertainty logic as
    /// ordinary world answers. Targets remain references, never borrowed facts.
    public func linkedWorldEvidence(recordID:String,requested:[WorldPredicate],permit:SnapshotPermit)throws->WorldAnswerItem {
        try check(permit);try WorldQueryEngine.validate(WorldMemoryQuery(requested:requested))
        guard let row=state.worldRows?[recordID],isWorldCurrent(row.projection,in:catalog!)else{throw MemoryError.staleResult}
        let rows=state.worldRows ?? [:]
        return try withSourceReadings(WorldAnswerItem(recordID:recordID,kind:row.projection.kind,
            fields:requested.map{WorldQueryEngine.field($0,of:row.projection,entities:rows,includeInferred:false)},
            unresolvedConstraints:[],matchingEvidence:[]))
    }

    @discardableResult
    public func applyWorldBatch(_ changes: [WorldMemoryWrite], permit: SnapshotPermit) throws -> [StoredWorldMemory] {
        try check(permit)
        guard changes.count <= 4096 else { throw MemoryError.unsupportedQuery }
        var unique: [String: WorldMemoryWrite] = [:]
        for change in changes {
            let id = change.projection.recordID
            if let other = unique[id], other != change { throw MemoryError.conflictingProjection }
            unique[id] = change
        }
        var prepared: [(StoredWorldMemory, String)] = []
        for id in unique.keys.sorted() {
            let change = unique[id]!, p = change.projection
            if let expected = change.expectedMemoryRevision {
                guard let old = state.recordRevisions[id], p.recordRevision > old,
                      state.memoryRevisions[id] == expected else { throw MemoryError.staleCorrection }
            } else if let old = state.recordRevisions[id], old != p.recordRevision { throw MemoryError.staleCorrection }
            try validateWorld(p)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let digest = SHA256.hash(data: try encoder.encode(p)).map { String(format: "%02x", $0) }.joined()
            if state.recordRevisions[id] == p.recordRevision, state.projectionDigests[id] != digest { throw MemoryError.conflictingProjection }
            if let old = state.worldRows?[id], old.projection == p { prepared.append((old, digest)) }
            else { prepared.append((StoredWorldMemory(projection: p, revision: state.generation + 1), digest)) }
        }
        guard prepared.contains(where: { state.worldRows?[$0.0.projection.recordID] != $0.0 }) else { return prepared.map(\.0) }
        var next = state; next.generation += 1; next.schema = max(next.schema,3)
        var rows = next.worldRows ?? [:], kinds = next.recordKinds ?? [:]
        for (row, digest) in prepared {
            let p = row.projection
            rows[p.recordID] = row; kinds[p.recordID] = .worldEntity
            next.recordRevisions[p.recordID] = p.recordRevision
            next.memoryRevisions[p.recordID] = row.revision; next.projectionDigests[p.recordID] = digest
        }
        next.worldRows = rows; next.recordKinds = kinds
        try commit(next); return prepared.map(\.0)
    }

    @discardableResult
    public func rebuildWorld(from projections: [WorldMemoryProjection], permit: SnapshotPermit) throws -> WorldRebuildReport {
        try check(permit)
        var active: [WorldMemoryWrite] = [], skipped: [ProjectionRebuildSkip] = []
        var unique: [String: WorldMemoryProjection] = [:]
        for p in projections {
            guard p.scope == scope else { throw MemoryError.scopeMismatch }
            if let old = unique[p.recordID], old != p { throw MemoryError.conflictingProjection }
            unique[p.recordID] = p
        }
        for id in unique.keys.sorted() {
            let p = unique[id]!
            if state.withdrawnRecords.contains(id) { skipped.append(ProjectionRebuildSkip(recordID: id, reason: .withdrawnRecord)); continue }
            if p.sources.contains(where: { state.forgottenSources.contains($0.id) }) { skipped.append(ProjectionRebuildSkip(recordID: id, reason: .forgottenSource)); continue }
            try validateWorld(p)
            let changed = state.recordRevisions[id].map { p.recordRevision > $0 } ?? false
            if changed, state.memoryRevisions[id] == nil { throw MemoryError.corruptStore }
            active.append(WorldMemoryWrite(p, expectedMemoryRevision: changed ? state.memoryRevisions[id] : nil))
        }
        let expected = Set(catalog!.records.values.filter { $0.effectiveKind == .worldEntity }.map(\.id)).subtracting(state.withdrawnRecords)
        guard Set(active.map { $0.projection.recordID }) == expected else { throw MemoryError.incompleteRebuild }
        return WorldRebuildReport(rows: try applyWorldBatch(active, permit: permit), skipped: skipped)
    }

    public func queryWorld(_ query: WorldMemoryQuery, requestID: UUID, permit: SnapshotPermit,
                           maximumEntities: Int = 256, coverage: RecallCoverage = .unknown,
                           sourceScope: Set<SourceReference>? = nil) throws -> PreparedWorldAnswer {
        try check(permit)
        let currentRows = state.worldRows ?? [:]
        let rows: [String: StoredWorldMemory]
        if let sourceScope {
            guard !sourceScope.isEmpty, sourceScope.allSatisfy({catalog?.sources[$0.id]?.reference == $0}), (1...4096).contains(maximumEntities) else { throw MemoryError.invalidEvidence }
            rows = currentRows.filter { _, row in
                let sources = row.projection.sources
                return !sources.isEmpty && sources.isSubset(of: sourceScope)
            }
        } else {
            guard (1...4096).contains(maximumEntities) else { throw MemoryError.unsupportedQuery }
            rows = currentRows
        }
        guard rows.count <= maximumEntities else { throw MemoryError.unsupportedQuery }
        let (matches, unresolved) = try WorldQueryEngine.execute(query, entities: rows)
        return PreparedWorldAnswer(requestID: requestID, matches: try matches.map(withSourceReadings),
            unresolved: try unresolved.map(withSourceReadings), coverage: coverage, permit: permit,
            sourceScopedRecordIDs: sourceScope == nil ? nil : Set(rows.keys))
    }

    /// Question-only plans may execute against the latest complete authority in
    /// one native turn; no model-visible world snapshot is silently reused.
    public func queryWorldCurrent(_ query: WorldMemoryQuery, requestID: UUID, maximumEntities: Int = 4096,
                                  coverage: RecallCoverage = .unknown) throws -> PreparedWorldAnswer {
        try queryWorld(query, requestID: requestID, permit: permit(), maximumEntities: maximumEntities, coverage: coverage)
    }

    @discardableResult
    public func admitWorld(_ answer: PreparedWorldAnswer, activeRequestID: UUID) throws -> PreparedWorldAnswer {
        do { try check(answer.permit) } catch { throw MemoryError.staleResult }
        guard answer.requestID == activeRequestID else { throw MemoryError.staleResult }
        return answer
    }

    /// Resolve only relationship fields the answer actually requests. Pin can
    /// display performer/organizer/venue details without a later unbound lookup.
    /// A single actor turn validates the original permit and all target facts.
    public func resolveWorldAnswer(_ answer: PreparedWorldAnswer, activeRequestID: UUID) throws -> ResolvedWorldAnswer {
        try admitWorld(answer, activeRequestID: activeRequestID)
        var related: [String: [WorldClaim]] = [:]
        for item in answer.matches + answer.unresolved {
            for field in item.fields where field.predicate.isRelationship {
                for claim in field.claims where claim.origin != .inferred {
                    if case .entity(let id) = claim.value { related[id, default: []].append(claim) }
                }
            }
        }
        let rows = state.worldRows ?? [:]
        let details = try related.keys.sorted().compactMap { id -> WorldAnswerItem? in
            guard answer.sourceScopedRecordIDs?.contains(id) != false, let row = rows[id] else { return nil }
            var requested: [WorldPredicate] = [.name]
            if row.projection.kind == .place { requested.append(.address) }
            return try withSourceReadings(WorldAnswerItem(recordID: id, kind: row.projection.kind,
                fields: requested.map { WorldQueryEngine.field($0, of: row.projection, entities: rows, includeInferred: false) },
                unresolvedConstraints: [], matchingEvidence: related[id]!))
        }
        return ResolvedWorldAnswer(answer: answer, relatedEntities: details)
    }

    public func bindWorldDisplayed(_ answer: PreparedWorldAnswer, orderedRecordIDs: [String], activeRequestID: UUID) throws -> WorldResultContext {
        try admitWorld(answer, activeRequestID: activeRequestID)
        let available = Set((answer.matches + answer.unresolved).map(\.recordID))
        guard Set(orderedRecordIDs).count == orderedRecordIDs.count, Set(orderedRecordIDs).isSubset(of: available) else { throw MemoryError.invalidContext }
        return WorldResultContext(answerID: activeRequestID, orderedRecordIDs: orderedRecordIDs, answer: answer)
    }

    public func worldDetail(ordinal: Int, requested: [WorldPredicate], context: WorldResultContext,
                            activeAnswerID: UUID) throws -> WorldAnswerItem {
        guard context.answerID == activeAnswerID else { throw MemoryError.invalidContext }
        try admitWorld(context.answer, activeRequestID: activeAnswerID)
        guard ordinal > 0, ordinal <= context.orderedRecordIDs.count else { throw MemoryError.invalidOrdinal }
        try WorldQueryEngine.validate(WorldMemoryQuery(requested: requested))
        let id = context.orderedRecordIDs[ordinal - 1]
        guard let row = state.worldRows?[id] else { throw MemoryError.staleResult }
        // This detail is about the selected entity even when the parent query
        // had unresolved constraints. It does not convert that candidate into
        // a confirmed match for the parent's conditions.
        guard let original = context.answer.matches.first(where: { $0.recordID == id }) ??
            context.answer.unresolved.first(where: { $0.recordID == id }) else { throw MemoryError.invalidContext }
        return try withSourceReadings(WorldAnswerItem(recordID: id, kind: row.projection.kind,
            fields: requested.map { WorldQueryEngine.field($0, of: row.projection, entities: state.worldRows ?? [:],
                includeInferred: false, sourceScopedRecordIDs: context.answer.sourceScopedRecordIDs) },
            unresolvedConstraints: original.unresolvedConstraints, matchingEvidence: original.matchingEvidence))
    }

    /// Resolve quality against the same current authority as the facts. Never
    /// infer a complete source read from a supported literal field value.
    private func withSourceReadings(_ item: WorldAnswerItem) throws -> WorldAnswerItem {
        guard let catalog else { throw MemoryError.needsSynchronization }
        let readings = try item.sources.sorted { ($0.id, $0.revision, $0.fingerprint) < ($1.id, $1.revision, $1.fingerprint) }.map { ref in
            guard let source = catalog.sources[ref.id], source.reference == ref else { throw MemoryError.staleResult }
            return WorldSourceReading(source: ref, assessment: source.readAssessment)
        }
        return WorldAnswerItem(recordID: item.recordID, kind: item.kind, fields: item.fields,
            unresolvedConstraints: item.unresolvedConstraints, matchingEvidence: item.matchingEvidence, sourceReadings: readings)
    }

    private func isWorldCurrent(_ p: WorldMemoryProjection, in catalog: Catalog) -> Bool {
        guard p.scope == scope, !state.withdrawnRecords.contains(p.recordID),
              let pin = catalog.records[p.recordID], pin.effectiveKind == .worldEntity,
              pin.revision == p.recordRevision, pin.sources == p.sources else { return false }
        for claim in p.claims{
            if case .date(let d)=claim.value{
                if let proof=d.temporalDerivation{
                    guard TemporalResolution.validates(d),let source=catalog.sources[proof.source.id],source.reference==proof.source,source.capturedAt==proof.originalCapturedAt,(source.captureTimestampOrigin==nil || source.captureTimestampOrigin==proof.captureOrigin),(proof.rule != .explicitRelativeDayFromOriginalCapture || proof.strength != .supportedContext || source.relativeDayAnchorContemporaneous == true),claim.anchors.contains(proof.dateAnchor)else{return false}
                }
                if claim.anchors.contains(where:{catalog.sources[$0.source.id]?.printedStartReadConflict == true}),d.certainty != .conflicting{return false}
            }
        }
        return p.sources.allSatisfy { !state.forgottenSources.contains($0.id) && catalog.sources[$0.id]?.reference == $0 } &&
            p.claims.allSatisfy { claim in
                var hasVisualEvidence = false
                for anchor in claim.anchors {
                    guard let kind = currentObservationKind(for: anchor, in: catalog) else { return false }
                    if claim.origin == .observed {
                        if claim.predicate == .visualLabel && kind != .visualLabel { return false }
                        if claim.predicate == .observedText && kind != .text { return false }
                    }
                    if kind == .visualLabel { hasVisualEvidence = true }
                }
                return claim.origin != .observed || claim.predicate != .depicts || hasVisualEvidence
            }
    }
    private func validateWorld(_ p: WorldMemoryProjection) throws {
        guard p.scope == scope else { throw MemoryError.scopeMismatch }
        guard !state.withdrawnRecords.contains(p.recordID) else { throw MemoryError.withdrawn }
        guard let catalog, isWorldCurrent(p, in: catalog), state.rows[p.recordID] == nil else { throw MemoryError.unvalidatedRecord }
        guard (1...256).contains(p.claims.count), Set(p.claims.map(\.id)).count == p.claims.count else { throw MemoryError.invalidEvidence }
        for c in p.claims {
            guard !c.id.isEmpty, c.id.utf8.count <= 1024, WorldQueryEngine.validValue(c.value, for: c.predicate),
                  (1...64).contains(c.anchors.count), !c.extractorVersion.isEmpty,
                  c.confidence.isFinite, (0...1).contains(c.confidence) else { throw MemoryError.invalidEvidence }
            for a in c.anchors {
                guard !a.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let source = catalog.sources[a.source.id], source.reference == a.source,
                      let observation = source.observations.first(where: { $0.id == a.observationID }),
                      observation.kind == .text ? observation.value.contains(a.quote) : observation.value == a.quote else { throw MemoryError.invalidEvidence }
            }
            if case .entity(let target) = c.value {
                // References can precede target projection installation in an
                // atomic batch, but target identity must already be host-owned.
                guard catalog.records[target]?.effectiveKind == .worldEntity,
                      !state.withdrawnRecords.contains(target) else { throw MemoryError.unvalidatedRecord }
            }
            if case .text(let text) = c.value, c.origin == .observed,
               [.name, .alias, .address, .identifier, .color, .material, .observedText, .visualLabel].contains(c.predicate) {
                var quotes: [String] = []
                for a in c.anchors where !quotes.contains(a.quote) { quotes.append(a.quote) }
                // observedText is an ordered transcription, so the same
                // printed label can occur in distinct source observations.
                // Identity/address fields retain the legacy deduplicated rule.
                let observations = c.anchors.map { $0.source.id + "\u{0}" + $0.observationID }
                let exactObservedSequence = c.predicate == .observedText &&
                    Set(observations).count == observations.count &&
                    c.anchors.map(\.quote).joined(separator: "\n") == text
                guard quotes.contains(text) || quotes.joined(separator: "\n") == text || quotes.joined(separator: " / ") == text || exactObservedSequence else { throw MemoryError.invalidEvidence }
            }
            if case .date(let date) = c.value {
                if let proof=date.temporalDerivation{
                    guard c.origin == .inferred,TemporalResolution.validates(date),let source=catalog.sources[proof.source.id],source.reference==proof.source,source.capturedAt==proof.originalCapturedAt,(source.captureTimestampOrigin==nil || source.captureTimestampOrigin==proof.captureOrigin),(proof.rule != .explicitRelativeDayFromOriginalCapture || proof.strength != .supportedContext || source.relativeDayAnchorContemporaneous == true),c.anchors.contains(proof.dateAnchor)else{throw MemoryError.invalidEvidence}
                }
                if c.anchors.contains(where:{catalog.sources[$0.source.id]?.printedStartReadConflict == true}){
                    guard date.certainty == .conflicting,[date.year,date.month,date.day,date.hour,date.minute,date.utcOffsetSeconds].allSatisfy({$0==nil}),date.timeZoneID==nil,date.printedDateText==nil,date.printedTimeText==nil else{throw MemoryError.invalidEvidence}
                }
                guard WorldQueryEngine.validDate(date),
                      date.certainty != .inferred || c.origin == .inferred,
                      date.captureYearDerivation == nil else { throw MemoryError.invalidEvidence }
                for printed in [date.printedDateText, date.printedTimeText].compactMap({ $0 }) {
                    guard c.anchors.contains(where: { $0.quote == printed }) else { throw MemoryError.invalidEvidence }
                }
            }
        }
    }

    private func checkOpen() throws { if isClosed { throw MemoryError.closed } }
    private func check(_ permit: SnapshotPermit) throws {
        try checkOpen()
        guard catalog != nil else { throw MemoryError.needsSynchronization }
        guard permit.session == session, permit.generation == state.generation,
              permit.catalogEpoch == catalogEpoch else { throw MemoryError.stalePermit }
    }
    private func isCurrent(_ projection: MemoryProjection, in catalog: Catalog) -> Bool {
        guard !state.withdrawnRecords.contains(projection.recordID), projection.scope == scope,
              let pin = catalog.records[projection.recordID], pin.effectiveKind == .appointment, pin.revision == projection.recordRevision,
              pin.sources == projection.sources else { return false }
        return appointmentDateIsCurrent(projection, in: catalog) && appointmentAnchorsAreCurrent(projection, in: catalog)
    }

    private func currentObservationKind(for anchor: EvidenceAnchor, in catalog: Catalog) -> ObservationKind? {
        guard let source = catalog.sources[anchor.source.id], source.reference == anchor.source,
              let observation = source.observations.first(where: { $0.id == anchor.observationID }),
              observation.kind == .text ? observation.value.contains(anchor.quote) : observation.value == anchor.quote else { return nil }
        return observation.kind
    }

    // Historical revisions retain source authority independently of the newer domain pin.
    private func appointmentDateIsCurrent(_ projection: MemoryProjection, in catalog: Catalog) -> Bool {
        if projection.support.first(where:{$0.field == .date})?.anchors.contains(where:{catalog.sources[$0.source.id]?.printedStartReadConflict == true}) == true,projection.appointment.date.certainty != .conflicting{return false}
        if let proof = projection.appointment.date.captureYearDerivation {
            guard CaptureYearPolicy.validates(projection.appointment.date), projection.sources.contains(proof.source),
                  let source = catalog.sources[proof.source.id], source.reference == proof.source,
                  source.capturedAt == proof.originalCapturedAt,source.captureTimestampOrigin != .importOrEdit else { return false }
        }
        if let proof=projection.appointment.date.temporalDerivation{
            guard TemporalResolution.validates(projection.appointment.date),projection.sources.contains(proof.source),let source=catalog.sources[proof.source.id],source.reference==proof.source,source.capturedAt==proof.originalCapturedAt,(source.captureTimestampOrigin==nil || source.captureTimestampOrigin==proof.captureOrigin),(proof.rule != .explicitRelativeDayFromOriginalCapture || proof.strength != .supportedContext || source.relativeDayAnchorContemporaneous == true),source.observations.contains(where:{$0.id==proof.dateAnchor.observationID && $0.value.contains(proof.dateAnchor.quote)}) else{return false}
        }
        return true
    }

    private func appointmentAnchorsAreCurrent(_ projection: MemoryProjection, in catalog: Catalog) -> Bool {
        projection.support.allSatisfy { field in
            field.anchors.allSatisfy { anchor in
                guard let kind = currentObservationKind(for: anchor, in: catalog) else { return false }
                return (field.field != .performer && field.field != .venueAddress) || kind == .text
            }
        }
    }
    private func validate(_ projection: MemoryProjection) throws {
        guard projection.scope == scope else { throw MemoryError.scopeMismatch }
        guard !state.withdrawnRecords.contains(projection.recordID) else { throw MemoryError.withdrawn }
        guard let catalog, let pin = catalog.records[projection.recordID], pin.effectiveKind == .appointment,
              pin.revision == projection.recordRevision, pin.sources == projection.sources,
              appointmentDateIsCurrent(projection, in: catalog),
              projection.sources.allSatisfy({ catalog.sources[$0.id]?.reference == $0 }) else { throw MemoryError.unvalidatedRecord }
        guard appointmentAnchorsAreCurrent(projection, in: catalog) else { throw MemoryError.invalidEvidence }
        let value = projection.appointment
        if projection.support.first(where:{$0.field == .date})?.anchors.contains(where:{catalog.sources[$0.source.id]?.printedStartReadConflict == true}) == true{
            let d=value.date
            guard d.certainty == .conflicting,[d.year,d.month,d.day,d.hour,d.minute,d.utcOffsetSeconds].allSatisfy({$0==nil}),d.timeZoneID==nil,d.printedDateText==nil,d.printedTimeText==nil else{throw MemoryError.invalidEvidence}
        }
        for text in [value.date.printedDateText, value.date.printedTimeText].compactMap({ $0 }) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  projection.support.first(where: { $0.field == .date })?.anchors.contains(where: { $0.quote == text }) == true else {
                throw MemoryError.invalidEvidence
            }
        }
        if value.date.captureYearDerivation != nil || value.date.temporalDerivation != nil {
            guard value.date.certainty == .inferred, projection.support.first(where: { $0.field == .date })?.origin == .inferred else { throw MemoryError.invalidEvidence }
        }
        var required:Set<AppointmentField>=[.title,.date,.kind,.status]
        let d=value.date
        let noTemporalClaim=[d.year,d.month,d.day,d.hour,d.minute,d.utcOffsetSeconds].allSatisfy{$0==nil} && d.timeZoneID==nil && d.printedDateText==nil && d.printedTimeText==nil && d.captureYearDerivation==nil && d.certainty == .explicit
        if projection.documentOnlyWithoutDate == true,noTemporalClaim {required.remove(.date)}
        if value.provider != nil { required.insert(.provider) }
        if value.venue != nil { required.insert(.venue) }
        if value.performer != nil { required.insert(.performer) }
        if value.venueAddress != nil { required.insert(.venueAddress) }
        for (field,text,separator) in [(AppointmentField.performer,value.performer," / "),(.venueAddress,value.venueAddress,"\n")] {
            if let text {
                guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,let support=projection.support.first(where:{$0.field==field}),(support.origin == .observed || support.origin == .domainCorrection) else{throw MemoryError.invalidEvidence}
                var unique:[String]=[]
                for anchor in support.anchors where !unique.contains(anchor.quote) { unique.append(anchor.quote) }
                guard unique.joined(separator:separator)==text else{throw MemoryError.invalidEvidence}
            }
        }
        guard !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.provider.map({ !$0.isEmpty }) ?? true, value.venue.map({ !$0.isEmpty }) ?? true,
              Set(projection.support.map(\.field)) == required, projection.support.count == required.count else { throw MemoryError.invalidEvidence }
        for field in projection.support {
            guard !field.anchors.isEmpty, !field.extractorVersion.isEmpty, field.confidence.isFinite,
                  (0...1).contains(field.confidence) else { throw MemoryError.invalidEvidence }
            if field.field == .date, field.origin == .inferred, value.date.certainty == .explicit { throw MemoryError.invalidEvidence }
            for anchor in field.anchors {
                guard !anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MemoryError.invalidEvidence }
            }
        }
    }
    private func prepare(_ projection: MemoryProjection, revision: UInt64) throws -> (StoredMemory, String) {
        try validate(projection)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(projection)).map { String(format: "%02x", $0) }.joined()
        if state.recordRevisions[projection.recordID] == projection.recordRevision,
           state.projectionDigests[projection.recordID] != digest { throw MemoryError.conflictingProjection }
        if let old = state.rows[projection.recordID], old.projection == projection { return (old, digest) }
        return (StoredMemory(projection: projection, revision: revision), digest)
    }
    private func install(_ row: StoredMemory, digest: String, into next: inout DiskState) {
        let projection = row.projection
        if projection.appointment.performer != nil || projection.appointment.venueAddress != nil || projection.documentOnlyWithoutDate == true {next.schema=max(next.schema,2)}
        if next.sourceChanges?[projection.recordID]?.current != projection {next.sourceChanges?.removeValue(forKey:projection.recordID)}
        next.rows[projection.recordID] = row; next.memoryRevisions[projection.recordID] = row.revision
        next.recordRevisions[projection.recordID] = projection.recordRevision
        next.projectionDigests[projection.recordID] = digest
    }
    private func put(_ projection: MemoryProjection) throws -> StoredMemory {
        let (row, digest) = try prepare(projection, revision: state.generation + 1)
        if state.rows[projection.recordID] == row { return row }
        var next = state; next.generation += 1
        install(row, digest: digest, into: &next)
        try commit(next); return row
    }
    private func commit(_ proposed: DiskState) throws {
        var next=proposed
        let usesTemporalEvidence=next.rows.values.contains{$0.projection.appointment.date.temporalDerivation != nil} || (next.worldRows?.values.contains{row in row.projection.claims.contains{c in if case .date(let d)=c.value{return d.temporalDerivation != nil};return false}} ?? false)
        next.schema=max(state.schema,next.schema,usesTemporalEvidence ? 4:1)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try file.write(encoder.encode(next)); state = next
        } catch {
            // A failure after rename can have committed. Poison this handle so
            // the caller must reopen and read disk before claiming an outcome.
            isClosed = true; catalog = nil; sourceIncarnations = [:]; file.close(); throw error
        }
    }
    internal func injectPersistenceFailure(_ hook: @escaping @Sendable (PersistenceStage) throws -> Void) {
        file.beforeReplace = hook
    }
}

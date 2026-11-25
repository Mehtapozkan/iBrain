import Foundation

/// Host-canonical entities, not an assertion that a depicted event was attended,
/// an object was purchased, or two similarly named things share an identity.
public enum WorldEntityKind: String, Codable, CaseIterable, Sendable {
    case person, organization, place, object, document, event, unspecified
}
public enum WorldPredicate: String, Codable, CaseIterable, Sendable {
    case name, alias, description, category, address, identifier, color, material, status, scheduledAt
    case observedText, visualLabel
    case locatedAt, performedBy, issuedBy, depicts, about
    public var isRelationship: Bool {
        switch self { case .locatedAt, .performedBy, .issuedBy, .depicts, .about: true; default: false }
    }
    public var isMultivalued: Bool {
        switch self { case .alias, .description, .depicts, .about, .performedBy, .issuedBy, .observedText, .visualLabel: true; default: false }
    }
}
public enum WorldValue: Codable, Equatable, Sendable {
    case text(String)
    case date(EventDate)
    /// A current host entity ID; never a model-generated merge key.
    case entity(String)
}
public struct WorldClaim: Codable, Equatable, Sendable {
    public let id: String
    public let predicate: WorldPredicate
    public let value: WorldValue
    public let origin: FactOrigin
    public let anchors: [EvidenceAnchor]
    public let confidence: Double
    public let extractorVersion: String
    public init(id: String, predicate: WorldPredicate, value: WorldValue, origin: FactOrigin = .observed,
                anchors: [EvidenceAnchor], confidence: Double = 1, extractorVersion: String) {
        self.id = id; self.predicate = predicate; self.value = value; self.origin = origin
        self.anchors = anchors; self.confidence = confidence; self.extractorVersion = extractorVersion
    }
}
/// A rebuildable projection of host-admitted claims. Source support proves
/// provenance, not semantic entailment. Interpreter qualification is separate.
public struct WorldMemoryProjection: Codable, Equatable, Sendable {
    public let recordID: String
    public let recordRevision: Int
    public let scope: MemoryScope
    public let kind: WorldEntityKind
    public let claims: [WorldClaim]
    public init(recordID: String, recordRevision: Int, scope: MemoryScope, kind: WorldEntityKind, claims: [WorldClaim]) {
        self.recordID = recordID; self.recordRevision = recordRevision; self.scope = scope
        self.kind = kind; self.claims = claims
    }
    public var sources: Set<SourceReference> { Set(claims.flatMap(\.anchors).map(\.source)) }
}
public struct StoredWorldMemory: Codable, Equatable, Sendable {
    public let projection: WorldMemoryProjection
    public let revision: UInt64
}
public struct WorldMemoryWrite: Equatable, Sendable {
    public let projection: WorldMemoryProjection
    /// Required for changed native revisions; nil means initial/exact replay.
    public let expectedMemoryRevision: UInt64?
    public init(_ projection: WorldMemoryProjection, expectedMemoryRevision: UInt64? = nil) {
        self.projection = projection; self.expectedMemoryRevision = expectedMemoryRevision
    }
}
public struct WorldSearchSnapshot: Sendable {
    public let scope: MemoryScope
    public let entities: [StoredWorldMemory]
    public let permit: SnapshotPermit
}
public struct WorldRebuildReport: Sendable {
    public let rows: [StoredWorldMemory]
    public let skipped: [ProjectionRebuildSkip]
}
public enum WorldTextComparison: String, Codable, Sendable { case exact, folded, phrase }
public struct WorldConstraint: Codable, Equatable, Sendable {
    /// Empty path checks the subject. A single relationship checks its target.
    public let path: [WorldPredicate]
    public let predicate: WorldPredicate
    public let value: WorldValue
    public let excluding: Bool
    public let comparison: WorldTextComparison?
    public let alternatives: [WorldValue]?
    public var effectiveComparison: WorldTextComparison { comparison ?? .exact }
    public var values: [WorldValue] { [value] + (alternatives ?? []) }
    public init(path: [WorldPredicate] = [], predicate: WorldPredicate, value: WorldValue, excluding: Bool = false,
                comparison: WorldTextComparison = .exact, alternatives: [WorldValue] = []) {
        self.path = path; self.predicate = predicate; self.value = value; self.excluding = excluding
        self.comparison = comparison == .exact ? nil : comparison; self.alternatives = alternatives.isEmpty ? nil : alternatives
    }
}
public struct WorldMemoryQuery: Codable, Equatable, Sendable {
    public let kind: WorldEntityKind?
    public let constraints: [WorldConstraint]
    public let requested: [WorldPredicate]
    /// Inferences are excluded from decisive matches by default, never promoted
    /// to observations. If opted in, claims still retain their inferred origin.
    public let includeInferred: Bool
    public init(kind: WorldEntityKind? = nil, constraints: [WorldConstraint] = [], requested: [WorldPredicate] = [.name],
                includeInferred: Bool = false) {
        self.kind = kind; self.constraints = constraints; self.requested = requested; self.includeInferred = includeInferred
    }
}
public enum WorldFieldState: String, Codable, Sendable { case known, partial, missing, conflicting, inferredOnly, unavailableTarget }
public struct WorldFieldAnswer: Codable, Equatable, Sendable {
    public let predicate: WorldPredicate
    public let state: WorldFieldState
    /// Alternatives are kept with their evidence; conflict never chooses one.
    public let claims: [WorldClaim]
}
public struct WorldAnswerItem: Codable, Equatable, Sendable {
    public let recordID: String
    public let kind: WorldEntityKind
    public let fields: [WorldFieldAnswer]
    public let unresolvedConstraints: [Int]
    /// Actual supporting claims along joins as well as the subject's matches.
    public let matchingEvidence: [WorldClaim]
    public let sourceReadings: [WorldSourceReading]?
    internal init(recordID: String, kind: WorldEntityKind, fields: [WorldFieldAnswer], unresolvedConstraints: [Int],
                  matchingEvidence: [WorldClaim], sourceReadings: [WorldSourceReading]? = nil) {
        self.recordID = recordID; self.kind = kind; self.fields = fields; self.unresolvedConstraints = unresolvedConstraints
        self.matchingEvidence = matchingEvidence; self.sourceReadings = sourceReadings
    }
    /// Completeness of requested admitted claims, not of reading an image.
    public var isComplete: Bool { unresolvedConstraints.isEmpty && fields.allSatisfy { $0.state == .known } }
    public var hasSourceReadingWarnings: Bool {
        guard let sourceReadings else { return !sources.isEmpty }
        return sourceReadings.contains { $0.warning != nil }
    }
    public var sources: Set<SourceReference> {
        Set((fields.flatMap(\.claims) + matchingEvidence).flatMap(\.anchors).map(\.source))
    }
}
public struct PreparedWorldAnswer: Sendable {
    public let requestID: UUID
    public let matches: [WorldAnswerItem]
    public let unresolved: [WorldAnswerItem]
    public let coverage: RecallCoverage
    public var canAssertCompletePersonalWorld: Bool { false }
    internal let permit: SnapshotPermit
    internal let sourceScopedRecordIDs: Set<String>?
}

/// Native deterministic evaluation of a bounded typed query. Semantic parsing,
/// candidate search and host admission are separate. No fuzzy identity, vector
/// score as truth, source absence as negation, or silently dropped constraints.
internal enum WorldQueryEngine {
    static func validate(_ query: WorldMemoryQuery) throws {
        guard query.constraints.count <= 16, (1...WorldPredicate.allCases.count).contains(query.requested.count),
              Set(query.requested).count == query.requested.count else { throw MemoryError.unsupportedQuery }
        for c in query.constraints {
            guard c.path.count <= 1, c.path.allSatisfy(\.isRelationship), (1...8).contains(c.values.count),
                  c.values.allSatisfy({ validValue($0, for: c.predicate) }) else { throw MemoryError.unsupportedQuery }
            if c.effectiveComparison != .exact {
                guard c.predicate != .identifier, c.values.allSatisfy({ if case .text = $0 { true } else { false } }) else { throw MemoryError.unsupportedQuery }
                if c.effectiveComparison == .phrase, ![WorldPredicate.address, .observedText, .description].contains(c.predicate) { throw MemoryError.unsupportedQuery }
            }
        }
    }
    static func validDate(_ d: EventDate) -> Bool {
        guard d.year.map({ (1...9999).contains($0) }) ?? true,
              d.month.map({ (1...12).contains($0) }) ?? true,
              d.day.map({ (1...31).contains($0) }) ?? true,
              d.hour.map({ (0...23).contains($0) }) ?? true,
              d.minute.map({ (0...59).contains($0) }) ?? true,
              d.timeZoneID.map({ TimeZone(identifier: $0) != nil }) ?? true,
              d.utcOffsetSeconds.map({ (-64800...64800).contains($0) }) ?? true,
              [d.year,d.month,d.day,d.hour,d.minute].contains(where: { $0 != nil }) else { return false }
        if let y = d.year, let m = d.month, let day = d.day {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = DateComponents(year: y, month: m, day: day)
            guard let value = calendar.date(from: components), calendar.dateComponents([.year,.month,.day], from: value) == components else { return false }
        }
        return true
    }
    static func validValue(_ value: WorldValue, for predicate: WorldPredicate) -> Bool {
        if predicate.isRelationship {
            if case .entity(let id) = value { return !id.isEmpty && id.utf8.count <= 1024 }; return false
        }
        if predicate == .scheduledAt { if case .date(let date) = value { return validDate(date) }; return false }
        if case .text(let text) = value { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 16_384 }
        return false
    }
    static func field(_ predicate: WorldPredicate, of row: WorldMemoryProjection,
                      entities: [String: StoredWorldMemory], includeInferred: Bool,
                      sourceScopedRecordIDs: Set<String>? = nil) -> WorldFieldAnswer {
        let all = row.claims.filter { $0.predicate == predicate }
        let claims = all.filter { includeInferred || $0.origin != .inferred }
        guard let first = claims.first else {
            return WorldFieldAnswer(predicate: predicate, state: all.isEmpty ? .missing : .inferredOnly, claims: all)
        }
        let state: WorldFieldState
        if !predicate.isMultivalued, claims.dropFirst().contains(where: { $0.value != first.value }) {
            state = .conflicting
        } else if predicate.isRelationship, claims.contains(where: { claim in
            guard case .entity(let id) = claim.value else { return false }
            return entities[id] == nil || sourceScopedRecordIDs?.contains(id) == false
        }) {
            state = .unavailableTarget
        } else if case .date(let date) = first.value {
            // Conflicting values were handled above. Equivalent date claims
            // share the same resolution while retaining every evidence anchor.
            if date.certainty == .conflicting { state = .conflicting }
            else if date.certainty == .inferred { state = .partial }
            else if case .uncertain = NativeDates.resolve(date) { state = .partial }
            else { state = .known }
        } else {
            state = .known
        }
        return WorldFieldAnswer(predicate: predicate, state: state, claims: claims)
    }
    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    private static func matches(_ value: WorldValue, constraint: WorldConstraint) -> Bool {
        constraint.values.contains { wanted in
            if constraint.effectiveComparison == .exact { return value == wanted }
            guard case .text(let lhs) = value, case .text(let rhs) = wanted else { return false }
            let haystack = folded(lhs), needle = folded(rhs)
            if constraint.effectiveComparison == .folded { return haystack == needle }
            guard !needle.isEmpty else { return false }
            var start = haystack.startIndex
            while start < haystack.endIndex, let range = haystack.range(of: needle, range: start..<haystack.endIndex) {
                let before = range.lowerBound == haystack.startIndex ? nil : haystack[haystack.index(before: range.lowerBound)]
                let after = range.upperBound == haystack.endIndex ? nil : haystack[range.upperBound]
                if !(before.map { $0.isLetter || $0.isNumber } ?? false) && !(after.map { $0.isLetter || $0.isNumber } ?? false) { return true }
                start = range.upperBound
            }
            return false
        }
    }
    private enum Verdict { case yes, no, unknown }
    private struct Check { let verdict: Verdict; let evidence: [WorldClaim] }
    private static func equal(_ c: WorldConstraint, row: WorldMemoryProjection,
                              entities: [String: StoredWorldMemory], includeInferred: Bool) -> Check {
        let f = field(c.predicate, of: row, entities: entities, includeInferred: includeInferred)
        guard f.state == .known else { return Check(verdict: .unknown, evidence: f.claims) }
        return Check(verdict: f.claims.contains { matches($0.value, constraint: c) } ? .yes : .no, evidence: f.claims)
    }
    private static func check(_ c: WorldConstraint, row: WorldMemoryProjection,
                              entities: [String: StoredWorldMemory], includeInferred: Bool) -> Check {
        let result: Check
        if let edge = c.path.first {
            let links = field(edge, of: row, entities: entities, includeInferred: includeInferred)
            guard links.state == .known || links.state == .unavailableTarget else {
                return Check(verdict: .unknown, evidence: links.claims)
            }
            // A verified member settles an existential match. Missing members
            // still prevent an absence claim when no known member matches.
            let checks = links.claims.map { claim -> Check in
                guard case .entity(let id) = claim.value, let target = entities[id] else {
                    return Check(verdict: .unknown, evidence: [])
                }
                return equal(c, row: target.projection, entities: entities, includeInferred: includeInferred)
            }
            let v: Verdict = checks.contains { $0.verdict == .yes } ? .yes : checks.contains { $0.verdict == .unknown } || checks.isEmpty ? .unknown : .no
            result = Check(verdict: v, evidence: links.claims + checks.flatMap(\.evidence))
        } else { result = equal(c, row: row, entities: entities, includeInferred: includeInferred) }
        guard c.excluding else { return result }
        // Negation requires positive known evidence; an absent property is not
        // proof that the entity satisfies an exclusion.
        return Check(verdict: result.verdict == .unknown ? .unknown : result.verdict == .yes ? .no : .yes, evidence: result.evidence)
    }
    static func execute(_ query: WorldMemoryQuery, entities: [String: StoredWorldMemory]) throws -> ([WorldAnswerItem], [WorldAnswerItem]) {
        try validate(query)
        var matched: [WorldAnswerItem] = [], unresolved: [WorldAnswerItem] = []
        let names = query.constraints.filter { $0.path.isEmpty && !$0.excluding && [.name, .alias].contains($0.predicate) }
        for row in entities.values.sorted(by: { $0.projection.recordID < $1.projection.recordID }) {
            let p = row.projection
            if let kind = query.kind, p.kind != kind { continue }
            // A named-entity lookup requires positive identity evidence. A
            // document with no admitted name is not a candidate for every
            // named place/person/object. Once named, missing OTHER requested
            // properties still remain unresolved rather than disappearing.
            if !names.allSatisfy({ c in p.claims.contains { $0.predicate == c.predicate && matches($0.value, constraint: c) && (query.includeInferred || $0.origin != .inferred) } }) { continue }
            let checks = query.constraints.map { check($0, row: p, entities: entities, includeInferred: query.includeInferred) }
            if checks.contains(where: { $0.verdict == .no }) { continue }
            let unknown = checks.indices.filter { checks[$0].verdict == .unknown }
            let item = WorldAnswerItem(recordID: p.recordID, kind: p.kind,
                fields: query.requested.map { field($0, of: p, entities: entities, includeInferred: query.includeInferred) },
                unresolvedConstraints: unknown, matchingEvidence: checks.flatMap(\.evidence))
            if unknown.isEmpty { matched.append(item) } else { unresolved.append(item) }
        }
        return (matched, unresolved)
    }
}

/// Answer data admitted in one native turn, including the names/addresses of
/// requested relationship targets. All original field states remain intact;
/// related details never turn an unresolved subject into a confirmed match.
public struct ResolvedWorldAnswer: Sendable {
    public let answer: PreparedWorldAnswer
    public let relatedEntities: [WorldAnswerItem]
}

/// Exact order actually displayed, scoped to one store session and answer.
/// The host cannot decode a stale result list or renumber it after forgetting.
public struct WorldResultContext: Sendable {
    public let answerID: UUID
    public let orderedRecordIDs: [String]
    internal let answer: PreparedWorldAnswer
}

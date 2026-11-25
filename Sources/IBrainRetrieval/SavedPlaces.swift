import Foundation
import IBrain

public enum SavedPlaceField: String, CaseIterable, Codable, Sendable {
    case name, category, city, neighborhood, branch, address, reason, subjectRole, visitDate
}

/// A role applies to this mention of a place, not to every place on the source.
public enum SavedPlaceRole: String, Codable, Sendable {
    case recommendation, listing, incidental, visit
}

public struct SavedPlaceFact: Codable, Equatable, Sendable {
    public let field: SavedPlaceField
    public let value: String
    public let origin: FactOrigin
    public let anchors: [EvidenceAnchor]
    public let extractorVersion: String

    public init(_ field: SavedPlaceField, value: String, origin: FactOrigin = .observed,
                anchors: [EvidenceAnchor], extractorVersion: String) {
        self.field = field
        self.value = value
        self.origin = origin
        self.anchors = anchors
        self.extractorVersion = extractorVersion
    }
}

/// One native-admitted mention on one source. Apply a correction to the current
/// native record before projecting it here. The evidence reader proposes facts.
public struct SavedPlaceMention: Codable, Equatable, Sendable {
    public let recordID: String
    public let recordRevision: Int
    public let source: SourceReference
    public let facts: [SavedPlaceFact]

    public init(recordID: String, recordRevision: Int, source: SourceReference, facts: [SavedPlaceFact]) {
        self.recordID = recordID
        self.recordRevision = recordRevision
        self.source = source
        self.facts = facts
    }
}

public struct SavedPlaceCoverage: Equatable, Sendable {
    /// Current allowed sources whose place reading is unfinished or unavailable.
    public let pendingSourceCount: Int
    /// Current sources read but not adjudicated for the place subject/roles.
    public let unresolvedSourceCount: Int

    public init(pendingSourceCount: Int, unresolvedSourceCount: Int) {
        self.pendingSourceCount = pendingSourceCount
        self.unresolvedSourceCount = unresolvedSourceCount
    }

    public var hasGaps: Bool { pendingSourceCount > 0 || unresolvedSourceCount > 0 }
}

public struct SavedPlaceCard: Equatable, Sendable {
    public let members: [SavedPlaceMention]
    public let id: String

    public var sources: [SourceReference] {
        var seen = Set<SourceReference>()
        return members.map(\.source).filter { seen.insert($0).inserted }
    }

    /// Missing facts return an empty array. Conflicting values keep their evidence.
    public func evidence(for field: SavedPlaceField) -> [SavedPlaceFact] {
        members.flatMap(\.facts).filter { $0.field == field && $0.origin != .inferred }
    }

    public func establishedValue(for field: SavedPlaceField) -> String? {
        consensus(evidence(for: field))
    }

    public var visitEvidence: [SavedPlaceFact] {
        members.filter { role($0) == .visit }.flatMap { facts(.subjectRole, in: $0) }
    }
}

public struct SavedPlaceAnswer: Sendable {
    public enum Operation: Sendable { case cityRestaurants, citySavedPlaces, cityVisits, neighborhood, visits }
    public let requestID: UUID
    public let operation: Operation
    public let cards: [SavedPlaceCard]
    public let unresolved: [SavedPlaceCard]
    public let coverage: SavedPlaceCoverage
    fileprivate let scope: MemoryScope
}

public struct SavedPlaceDisplayedContext: Sendable {
    public let answerRequestID: UUID
    public let orderedCardIDs: [String]
    public let coverage: SavedPlaceCoverage
    fileprivate let cards: [SavedPlaceCard]
    fileprivate let scope: MemoryScope
}

public enum SavedPlaceError: Error, Equatable {
    case invalidAuthority, invalidMention, staleDisplayedContext, invalidDisplayedOrder, invalidIntent, unresolvedExclusion
}

public struct SavedPlaceCatalog: Sendable {
    public static let version = "saved-places-v2.1"
    public let scope: MemoryScope
    public let coverage: SavedPlaceCoverage
    private let mentions: [SavedPlaceMention]
    private let byID: [String: SavedPlaceMention]

    /// Pin supplies current readable observations, mentions and their native record pins.
    /// An unadmitted or stale binding is an error, never a reason to publish a partial old answer.
    public init(scope: MemoryScope, authority: AuthoritySnapshot, mentions: [SavedPlaceMention],
                coverage: SavedPlaceCoverage) throws {
        let sources = Dictionary(grouping: authority.sources, by: { $0.reference.id })
        let records = Dictionary(grouping: authority.records, by: \.id)
        guard sources.values.allSatisfy({ $0.count == 1 && $0[0].scope == scope }),
              records.values.allSatisfy({ $0.count == 1 }), coverage.pendingSourceCount >= 0,
              coverage.unresolvedSourceCount >= 0,
              coverage.pendingSourceCount >= authority.pendingSourcePreparations.count
        else { throw SavedPlaceError.invalidAuthority }
        var admitted: [String: SavedPlaceMention] = [:]
        for mention in mentions {
            guard !mention.recordID.isEmpty, admitted[mention.recordID] == nil,
                  let record = records[mention.recordID]?.first, record.effectiveKind == .worldEntity,
                  record.revision == mention.recordRevision, record.sources == [mention.source],
                  let source = sources[mention.source.id]?.first, source.reference == mention.source,
                  !mention.facts.isEmpty,
                  !mention.facts.contains(where: { $0.field == .visitDate }) || role(mention) == .visit,
                  mention.facts.allSatisfy({ valid($0, on: source) })
            else { throw SavedPlaceError.invalidMention }
            admitted[mention.recordID] = mention
        }
        self.scope = scope
        self.coverage = coverage
        self.mentions = mentions.sorted { $0.recordID < $1.recordID }
        self.byID = admitted
    }

    public func restaurants(in city: String, requestID: UUID) throws -> SavedPlaceAnswer {
        try select(in: city, category: "restaurant", role: .recommendation,
                   operation: .cityRestaurants, requestID: requestID)
    }

    public func savedPlaces(in city: String, category: String? = nil, excluding name: String? = nil,
                            requestID: UUID) throws -> SavedPlaceAnswer {
        try select(in: city, category: category, role: .recommendation,
                   operation: .citySavedPlaces, excluding: name, requestID: requestID)
    }

    public func visits(in city: String, category: String? = nil, requestID: UUID) throws -> SavedPlaceAnswer {
        try select(in: city, category: category, role: .visit, operation: .cityVisits, requestID: requestID)
    }

    private func select(in city: String, category: String?, role requestedRole: SavedPlaceRole,
                        operation: SavedPlaceAnswer.Operation, excluding name: String? = nil,
                        requestID: UUID) throws -> SavedPlaceAnswer {
        guard !key(city).isEmpty, category.map({ !key($0).isEmpty }) ?? true
        else { throw SavedPlaceError.invalidIntent }
        var matches: [SavedPlaceCard] = []
        var unresolved: [SavedPlaceCard] = []
        for card in groupedCards(requiredRole: requestedRole) {
            let knownCity = card.establishedValue(for: .city)
            let knownCategory = card.establishedValue(for: .category)
            if let knownCity, !same(knownCity, city) { continue }
            if let category, let knownCategory, !same(knownCategory, category) { continue }
            if knownCity == nil || (category != nil && knownCategory == nil) {
                unresolved.append(card)
            } else {
                matches.append(card)
            }
        }
        let omitted = try excludedIDs(named: name, among: matches + unresolved)
        return answer(requestID, operation, cards: matches.filter { !omitted.contains($0.id) },
                      unresolved: unresolved.filter { !omitted.contains($0.id) })
    }

    public func displayedContext(for answer: SavedPlaceAnswer, orderedCardIDs: [String])
    throws -> SavedPlaceDisplayedContext {
        guard answer.scope == scope else { throw SavedPlaceError.staleDisplayedContext }
        try validate(answer.cards + answer.unresolved)
        let cards = Dictionary(uniqueKeysWithValues: answer.cards.map { ($0.id, $0) })
        guard orderedCardIDs.count == cards.count, Set(orderedCardIDs) == Set(cards.keys)
        else { throw SavedPlaceError.invalidDisplayedOrder }
        return SavedPlaceDisplayedContext(answerRequestID: answer.requestID, orderedCardIDs: orderedCardIDs,
                                          coverage: answer.coverage, cards: orderedCardIDs.compactMap { cards[$0] },
                                          scope: scope)
    }

    public func refine(_ context: SavedPlaceDisplayedContext, parentRequestID: UUID,
                       neighborhood: String, category: String? = nil, excluding name: String? = nil,
                       requestID: UUID) throws -> SavedPlaceAnswer {
        guard !key(neighborhood).isEmpty, category.map({ !key($0).isEmpty }) ?? true
        else { throw SavedPlaceError.invalidIntent }
        try validate(context, parentRequestID)
        var matches = [SavedPlaceCard]()
        var unresolved = [SavedPlaceCard]()
        for card in context.cards {
            let knownNeighborhood = card.establishedValue(for: .neighborhood)
            let knownCategory = card.establishedValue(for: .category)
            if let knownNeighborhood, !same(knownNeighborhood, neighborhood) { continue }
            if let category, let knownCategory, !same(knownCategory, category) { continue }
            if knownNeighborhood == nil || (category != nil && knownCategory == nil) {
                unresolved.append(card)
            } else {
                matches.append(card)
            }
        }
        let omitted = try excludedIDs(named: name, among: matches + unresolved)
        return answer(requestID, .neighborhood, cards: matches.filter { !omitted.contains($0.id) },
                      unresolved: unresolved.filter { !omitted.contains($0.id) }, coverage: context.coverage)
    }

    public func visits(in context: SavedPlaceDisplayedContext, parentRequestID: UUID,
                       requestID: UUID) throws -> SavedPlaceAnswer {
        try validate(context, parentRequestID)
        let matches = context.cards.filter { !$0.visitEvidence.isEmpty }
        let unresolved = context.cards.filter { $0.visitEvidence.isEmpty }
        return answer(requestID, .visits, cards: matches, unresolved: unresolved, coverage: context.coverage)
    }

    public func originals(for cardID: String, in context: SavedPlaceDisplayedContext,
                          parentRequestID: UUID) throws -> [SourceReference] {
        try validate(context, parentRequestID)
        guard let card = context.cards.first(where: { $0.id == cardID })
        else { throw SavedPlaceError.invalidDisplayedOrder }
        return card.sources
    }

    /// A named exclusion binds to a unique card in the eligible collection.
    /// Dropping a trailing type word is permitted only for a supported category.
    /// Missing or ambiguous names require clarification before an answer can publish.
    private func excludedIDs(named name: String?, among cards: [SavedPlaceCard]) throws -> Set<String> {
        guard let name else { return [] }
        let requested = key(name)
        guard !requested.isEmpty else { throw SavedPlaceError.invalidIntent }
        let matches = cards.filter { card in
            guard let title = card.establishedValue(for: .name) else { return false }
            let full = key(title)
            if full == requested { return true }
            let suffixes: [String]
            switch card.establishedValue(for: .category).map(key) {
            case "cafe": suffixes = [" cafe", " café", " coffee shop"]
            case "restaurant": suffixes = [" restaurant"]
            default: suffixes = []
            }
            return suffixes.contains { suffix in
                full.hasSuffix(suffix) && String(full.dropLast(suffix.count)) == requested
            }
        }
        guard matches.count == 1, let match = matches.first else { throw SavedPlaceError.unresolvedExclusion }
        return [match.id]
    }

    private func answer(_ requestID: UUID, _ operation: SavedPlaceAnswer.Operation,
                        cards: [SavedPlaceCard], unresolved: [SavedPlaceCard],
                        coverage: SavedPlaceCoverage? = nil) -> SavedPlaceAnswer {
        SavedPlaceAnswer(requestID: requestID, operation: operation, cards: cards, unresolved: unresolved,
                         coverage: coverage ?? self.coverage, scope: scope)
    }

    private func validate(_ context: SavedPlaceDisplayedContext, _ parent: UUID) throws {
        guard context.scope == scope, context.answerRequestID == parent
        else { throw SavedPlaceError.staleDisplayedContext }
        try validate(context.cards)
    }

    private func validate(_ cards: [SavedPlaceCard]) throws {
        guard cards.flatMap(\.members).allSatisfy({ byID[$0.recordID] == $0 })
        else { throw SavedPlaceError.staleDisplayedContext }
    }

    private func groupedCards(requiredRole: SavedPlaceRole) -> [SavedPlaceCard] {
        let eligible = mentions.filter {
            guard let role = role($0), role != .incidental else { return false }
            return value(.name, in: $0) != nil
        }
        let byName = Dictionary(grouping: eligible) { key(value(.name, in: $0) ?? "") }
        return byName.values.flatMap(group).compactMap { members in
            let ordered = members.sorted { $0.recordID < $1.recordID }
            guard let member = ordered.first(where: { role($0) == requiredRole }) else { return nil }
            return SavedPlaceCard(members: ordered, id: member.recordID)
        }.sorted { $0.id < $1.id }
    }

    private func group(_ mentions: [SavedPlaceMention]) -> [[SavedPlaceMention]] {
        let strong = Dictionary(uniqueKeysWithValues: mentions.map { lhs in
            (lhs.recordID, Set(mentions.filter { $0.recordID != lhs.recordID && strongBranchMatch(lhs, $0) }.map(\.recordID)))
        })
        var grouped: [[SavedPlaceMention]] = []
        var used = Set<String>()
        // Only cliques can merge. An intermediate ambiguous record cannot bridge disjoint branches.
        for mention in mentions where !used.contains(mention.recordID) {
            let neighbors = strong[mention.recordID, default: []]
            let cluster = neighbors.union([mention.recordID])
            if cluster.count > 1 && neighbors.allSatisfy({ strong[$0, default: []].union([$0]) == cluster }) {
                grouped.append(mentions.filter { cluster.contains($0.recordID) })
                used.formUnion(cluster)
            }
        }
        let singles = mentions.filter { !used.contains($0.recordID) }
        // The only weaker join is an unambiguous recommendation plus explicit
        // neighborhood-named listing. It cannot link a visit or two recommendations.
        let links = Dictionary(uniqueKeysWithValues: mentions.map { lhs in
            (lhs.recordID, mentions.filter {
                $0.recordID != lhs.recordID && (strongBranchMatch(lhs, $0) || neighborhoodListingMatch(lhs, $0))
            })
        })
        for mention in singles where !used.contains(mention.recordID) {
            if let candidates = links[mention.recordID], candidates.count == 1, let other = candidates.first,
               !used.contains(other.recordID), links[other.recordID]?.count == 1,
               neighborhoodListingMatch(mention, other) {
                grouped.append([mention, other])
                used.insert(other.recordID)
            } else {
                grouped.append([mention])
            }
            used.insert(mention.recordID)
        }
        return grouped
    }
}

private func valid(_ fact: SavedPlaceFact, on source: SourceSnapshot) -> Bool {
    guard !key(fact.value).isEmpty, !fact.extractorVersion.isEmpty else { return false }
    if fact.field == .subjectRole && SavedPlaceRole(rawValue: fact.value) == nil { return false }
    if fact.origin == .domainCorrection && fact.anchors.isEmpty { return true }
    if fact.origin == .observed && fact.field != .category && fact.field != .subjectRole {
        guard showsValue(fact, on: source) else { return false }
    }
    return !fact.anchors.isEmpty && fact.anchors.allSatisfy { anchor in
        guard anchor.source == source.reference, !key(anchor.quote).isEmpty else { return false }
        let observations = source.observations.filter { $0.id == anchor.observationID }
        guard observations.count == 1, let observation = observations.first else { return false }
        return observation.kind == .text ? observation.value.contains(anchor.quote) : observation.value == anchor.quote
    }
}

/// A detail may wrap onto consecutive OCR lines. Validate the text on each
/// line separately and only combine neighboring lines in the source order.
private func showsValue(_ fact: SavedPlaceFact, on source: SourceSnapshot) -> Bool {
    if fact.anchors.contains(where: { $0.quote.contains(fact.value) }) { return true }
    guard fact.anchors.count > 1 else { return false }
    let positions = fact.anchors.compactMap { anchor in
        source.observations.firstIndex { $0.id == anchor.observationID && $0.kind == .text }
    }
    return positions.count == fact.anchors.count &&
        zip(positions, positions.dropFirst()).allSatisfy { $1 == $0 + 1 } &&
        fact.anchors.map(\.quote).joined(separator: " ").contains(fact.value)
}

private func key(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func same(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs, let rhs else { return false }
    return key(lhs) == key(rhs)
}

private func consensus(_ facts: [SavedPlaceFact]) -> String? {
    guard let first = facts.first, facts.allSatisfy({ same($0.value, first.value) }) else { return nil }
    return first.value
}

private func facts(_ field: SavedPlaceField, in mention: SavedPlaceMention) -> [SavedPlaceFact] {
    mention.facts.filter { $0.field == field && $0.origin != .inferred }
}

private func value(_ field: SavedPlaceField, in mention: SavedPlaceMention) -> String? {
    consensus(facts(field, in: mention))
}

private func role(_ mention: SavedPlaceMention) -> SavedPlaceRole? {
    value(.subjectRole, in: mention).flatMap(SavedPlaceRole.init(rawValue:))
}

private func compatible(_ lhs: SavedPlaceMention, _ rhs: SavedPlaceMention) -> Bool {
    guard same(value(.city, in: lhs), value(.city, in: rhs)) else { return false }
    return [SavedPlaceField.category, .branch, .neighborhood, .address].allSatisfy { field in
        let left = facts(field, in: lhs)
        let right = facts(field, in: rhs)
        return left.isEmpty || right.isEmpty
            ? (left.isEmpty || consensus(left) != nil) && (right.isEmpty || consensus(right) != nil)
            : same(consensus(left), consensus(right))
    }
}

private func strongBranchMatch(_ lhs: SavedPlaceMention, _ rhs: SavedPlaceMention) -> Bool {
    guard compatible(lhs, rhs) else { return false }
    if same(value(.address, in: lhs), value(.address, in: rhs)) { return true }
    let branch = value(.branch, in: lhs)
    guard same(branch, value(.branch, in: rhs)) else { return false }
    let leftArea = value(.neighborhood, in: lhs)
    let rightArea = value(.neighborhood, in: rhs)
    if same(leftArea, rightArea) { return true }
    return (leftArea == nil && same(branch, rightArea)) || (rightArea == nil && same(branch, leftArea))
}

private func neighborhoodListingMatch(_ lhs: SavedPlaceMention, _ rhs: SavedPlaceMention) -> Bool {
    let (recommendation, listing) = role(lhs) == .recommendation ? (lhs, rhs) : (rhs, lhs)
    guard role(recommendation) == .recommendation, role(listing) == .listing,
          value(.branch, in: recommendation) == nil, value(.address, in: recommendation) == nil,
          same(value(.category, in: recommendation), value(.category, in: listing)),
          compatible(recommendation, listing)
    else { return false }
    return same(value(.neighborhood, in: recommendation), value(.branch, in: listing))
        && same(value(.neighborhood, in: recommendation), value(.neighborhood, in: listing))
}

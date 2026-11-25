import Foundation
import IBrain

/// Deterministic transfer of admitted observations into retrievable memory.
/// This does not classify raw OCR, infer a title/ownership, or turn a poster
/// into a booking. Visual labels retain their original reader's provenance.
public enum WorldObservationCompiler {
    public static func document(source: SourceSnapshot, recordID: String, recordRevision: Int,
                                extractorVersion: String) throws -> WorldMemoryProjection {
        guard !extractorVersion.isEmpty, !source.observations.isEmpty, source.observations.count <= 256 else {
            throw SemanticError.unsupportedEvidence
        }
        return WorldMemoryProjection(recordID: recordID, recordRevision: recordRevision, scope: source.scope, kind: .document,
            claims: source.observations.map { o in
                WorldClaim(id: o.id, predicate: o.kind == .text ? .observedText : .visualLabel, value: .text(o.value),
                    anchors: [EvidenceAnchor(source: source.reference, observationID: o.id, quote: o.value)],
                    confidence: 0, extractorVersion: extractorVersion)
            })
    }
}

/// IDs and revisions are supplied by the authoritative host, never generated
/// from matching names. A venue at a different address may be a different
/// entity; this pure compiler does not decide identity or temporal validity.
public struct AppointmentWorldIdentities: Sendable {
    public let eventID: String
    public let venueID: String?
    public let performerID: String?
    public let revision: Int
    public init(eventID: String, venueID: String? = nil, performerID: String? = nil, revision: Int) {
        self.eventID = eventID; self.venueID = venueID; self.performerID = performerID; self.revision = revision
    }
}
public enum AppointmentWorldProjectionPolicy:Sendable {case legacyV1,typedTemporalValuesV2}
public enum AppointmentWorldCompiler {
    /// Compile only already host-admitted fields. No new model inference,
    /// no global entity merge, no claim the user attended or owns a ticket.
    public static func compile(_ p: MemoryProjection, identities: AppointmentWorldIdentities, policy:AppointmentWorldProjectionPolicy = .legacyV1) throws -> [WorldMemoryProjection] {
        let a = p.appointment
        guard !identities.eventID.isEmpty, identities.revision > 0,
              (a.venue == nil) == (identities.venueID == nil),
              (a.performer == nil) == (identities.performerID == nil) else { throw SemanticError.unsupportedEvidence }
        let ids = [identities.eventID, identities.venueID, identities.performerID].compactMap { $0 }
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else { throw SemanticError.unsupportedEvidence }
        func claim(_ field: AppointmentField, _ predicate: WorldPredicate, _ value: WorldValue) throws -> WorldClaim {
            guard let support = p.support.first(where: { $0.field == field }) else { throw SemanticError.unsupportedEvidence }
            return WorldClaim(id: field.rawValue, predicate: predicate, value: value, origin: support.origin,
                anchors: support.anchors, confidence: support.confidence, extractorVersion: support.extractorVersion)
        }
        var event = [try claim(.title, .name, .text(a.title)), try claim(.status, .status, .text(a.status.rawValue)),
                     try claim(.kind, .category, .text(a.kind.rawValue))]
        if p.support.contains(where: { $0.field == .date }) {
            // Capture-year policy belongs to the host's dated appointment
            // route; this initial world adapter refuses to detach that proof.
            guard a.date.captureYearDerivation == nil else { throw SemanticError.unsupportedEvidence }
            if policy == .legacyV1 || [a.date.year,a.date.month,a.date.day,a.date.hour,a.date.minute].contains(where:{$0 != nil}) {event.append(try claim(.date, .scheduledAt, .date(a.date)))}
        }
        var entities: [WorldMemoryProjection] = []
        if let id = identities.venueID, let venue = a.venue {
            var facts = [try claim(.venue, .name, .text(venue))]
            if let address = a.venueAddress { facts.append(try claim(.venueAddress, .address, .text(address))) }
            entities.append(WorldMemoryProjection(recordID: id, recordRevision: identities.revision, scope: p.scope, kind: .place, claims: facts))
            event.append(try claim(.venue, .locatedAt, .entity(id)))
        }
        if let id = identities.performerID, let performer = a.performer {
            // The field establishes performer role, not person-versus-band.
            // Use an unspecified entity for the named performer until host semantic
            // evidence establishes a more specific kind.
            entities.append(WorldMemoryProjection(recordID: id, recordRevision: identities.revision, scope: p.scope, kind: .unspecified,
                claims: [try claim(.performer, .name, .text(performer))]))
            event.append(try claim(.performer, .performedBy, .entity(id)))
        }
        entities.append(WorldMemoryProjection(recordID: identities.eventID, recordRevision: identities.revision, scope: p.scope, kind: .event, claims: event))
        return entities
    }
}

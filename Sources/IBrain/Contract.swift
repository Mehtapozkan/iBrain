import Foundation

public enum IBrain { public static let apiVersion = "0.36.3" }

/// One private owner namespace. This version provides no sharing operation.
public struct MemoryScope: Codable, Hashable, Sendable {
    public let ownerID: String
    public let namespace: String
    public init(ownerID: String, namespace: String) { self.ownerID = ownerID; self.namespace = namespace }
}

public struct SourceReference: Codable, Hashable, Sendable {
    public let id: String
    public let revision: Int
    public let fingerprint: String
    public init(id: String, revision: Int, fingerprint: String) {
        self.id = id; self.revision = revision; self.fingerprint = fingerprint
    }
}

public enum ObservationKind: String, Codable, Sendable { case text, visualLabel }
public struct SourceObservation: Codable, Equatable, Sendable {
    public let id: String
    public let kind: ObservationKind
    public let value: String
    public init(id: String, kind: ObservationKind = .text, value: String) {
        self.id = id; self.kind = kind; self.value = value
    }
}

/// Only sources currently readable by this private owner may be included.
/// `capturedAt` is context. Only an explicit host-approved capture-year policy
/// may use an attested original capture with a printed month/day; it is never
/// a substitute for the event date or a missing timezone.
public struct ObservationReadingProvenance:Codable,Equatable,Sendable{
    public let sourceAtRead:SourceReference
    public let receiptSHA256:String
    public init(sourceAtRead:SourceReference,receiptSHA256:String){self.sourceAtRead=sourceAtRead;self.receiptSHA256=receiptSHA256}
}
public struct SourceSnapshot: Codable, Equatable, Sendable {
    public let reference: SourceReference
    public let scope: MemoryScope
    public let observations: [SourceObservation]
    public let capturedAt: Date?
    public let captureTimestampOrigin:CaptureTimestampOrigin?
    public let importedAt:Date?
    public let relativeDayAnchorContemporaneous:Bool?
    public let readAssessment: SourceReadAssessment?
    public let readingProvenance:[String:ObservationReadingProvenance]?
    public let printedStartReadConflict:Bool?
    public init(reference: SourceReference, scope: MemoryScope, observations: [SourceObservation], capturedAt: Date? = nil,
                readAssessment: SourceReadAssessment? = nil,readingProvenance:[String:ObservationReadingProvenance]? = nil,printedStartReadConflict:Bool = false,captureTimestampOrigin:CaptureTimestampOrigin? = nil,importedAt:Date? = nil,relativeDayAnchorContemporaneous:Bool? = nil) {
        self.reference = reference; self.scope = scope; self.observations = observations; self.capturedAt = capturedAt
        self.readAssessment = readAssessment
        self.captureTimestampOrigin=captureTimestampOrigin;self.importedAt=importedAt;self.relativeDayAnchorContemporaneous=relativeDayAnchorContemporaneous
        self.readingProvenance=readingProvenance;self.printedStartReadConflict=printedStartReadConflict ? true:nil
    }
}

/// Revision of a record validated by the host's domain writer. IDs are host
/// canonical record IDs, not photo IDs or a hash of provider + appointment time.
public enum DomainRecordKind: String, Codable, Sendable { case appointment, worldEntity }
public struct DomainRecordPin: Codable, Equatable, Sendable {
    public let id: String
    public let revision: Int
    public let sources: Set<SourceReference>
    public let recordKind: DomainRecordKind?
    public var effectiveKind: DomainRecordKind { recordKind ?? .appointment }
    public init(id: String, revision: Int, sources: Set<SourceReference>, recordKind: DomainRecordKind = .appointment) {
        self.id = id; self.revision = revision; self.sources = sources
        self.recordKind = recordKind == .appointment ? nil : recordKind
    }
}

public struct AuthoritySnapshot: Equatable, Sendable {
    public let sources: [SourceSnapshot]
    public let records: [DomainRecordPin]
    /// Host-known unfinished interpretation, even when a readable source already
    /// supports a canonical record. Negative coverage only, not a certificate
    /// that an empty set establishes every depicted object has been extracted.
    /// Host must restore this from current preparation state after reopening.
    public let pendingSourcePreparations: Set<SourceReference>
    public init(sources: [SourceSnapshot], records: [DomainRecordPin], pendingSourcePreparations: Set<SourceReference> = []) {
        self.sources = sources; self.records = records
        self.pendingSourcePreparations = pendingSourcePreparations
    }
}

public enum FactOrigin: String, Codable, Sendable { case observed, inferred, domainCorrection }
public enum AppointmentField: String, Codable, CaseIterable, Sendable { case title, date, provider, venue, kind, status, performer, venueAddress }
public struct EvidenceAnchor: Codable, Equatable, Sendable {
    public let source: SourceReference
    public let observationID: String
    /// Exact text substring, or the complete label for a visual observation.
    public let quote: String
    public init(source: SourceReference, observationID: String, quote: String) {
        self.source = source; self.observationID = observationID; self.quote = quote
    }
}
public struct FieldSupport: Codable, Equatable, Sendable {
    public let field: AppointmentField
    public let origin: FactOrigin
    public let anchors: [EvidenceAnchor]
    public let confidence: Double
    public let extractorVersion: String
    public init(field: AppointmentField, origin: FactOrigin = .observed, anchors: [EvidenceAnchor],
                confidence: Double = 1, extractorVersion: String) {
        self.field = field; self.origin = origin; self.anchors = anchors
        self.confidence = confidence; self.extractorVersion = extractorVersion
    }
}

public enum DateCertainty: String, Codable, Sendable { case explicit, inferred, conflicting }
public struct CaptureYearDerivation: Codable, Equatable, Sendable {
    public let policyVersion: String
    public let source: SourceReference
    public let originalCapturedAt: Date
    public let printedWeekday: Int?
}
public struct EventDate: Codable, Equatable, Sendable {
    public let year: Int?
    public let month: Int?
    public let day: Int?
    public let hour: Int?
    public let minute: Int?
    public let timeZoneID: String?
    public let utcOffsetSeconds: Int?
    public let certainty: DateCertainty
    public let captureYearDerivation: CaptureYearDerivation?
    public let temporalDerivation:TemporalDerivation?
    /// Copied evidence only; these strings never supply calendar components.
    public let printedDateText: String?
    public let printedTimeText: String?
    public init(year: Int?, month: Int?, day: Int?, hour: Int?, minute: Int?, timeZoneID: String?,
                utcOffsetSeconds: Int? = nil, certainty: DateCertainty = .explicit, captureYearDerivation: CaptureYearDerivation? = nil,
                printedDateText: String? = nil, printedTimeText: String? = nil,temporalDerivation:TemporalDerivation? = nil) {
        self.year = year; self.month = month; self.day = day; self.hour = hour; self.minute = minute
        self.timeZoneID = timeZoneID; self.utcOffsetSeconds = utcOffsetSeconds; self.certainty = certainty
        self.captureYearDerivation = captureYearDerivation;self.temporalDerivation=temporalDerivation
        self.printedDateText = printedDateText; self.printedTimeText = printedTimeText
    }
}
public enum AppointmentKind: String, Codable, Sendable { case appointment, eventTicket }
public enum AppointmentStatus: String, Codable, Sendable { case scheduled, cancelled }
public struct AppointmentProjection: Codable, Equatable, Sendable {
    public let title: String
    public let provider: String?
    public let venue: String?
    public let performer: String?
    public let venueAddress: String?
    public let date: EventDate
    public let kind: AppointmentKind
    public let status: AppointmentStatus
    public init(title: String, provider: String? = nil, venue: String? = nil, date: EventDate,
                kind: AppointmentKind = .appointment, status: AppointmentStatus = .scheduled, performer: String? = nil, venueAddress: String? = nil) {
        self.title = title; self.provider = provider; self.venue = venue; self.date = date
        self.kind = kind; self.status = status; self.performer = performer; self.venueAddress = venueAddress
    }
    public var displayTitle: String { [performer,title].compactMap{$0}.reduce(into:[String]()){if !$0.contains($1){$0.append($1)}}.joined(separator:" — ") }
    public var displayVenue: String? { let parts=[venue,venueAddress].compactMap{$0}.reduce(into:[String]()){if !$0.contains($1){$0.append($1)}};return parts.isEmpty ? nil:parts.joined(separator:"\n") }
}

/// Host-admitted semantics, with mechanical validation performed again here.
/// This is a projection of a native record, not an extraction approval API.
public struct MemoryProjection: Codable, Equatable, Sendable {
    public let recordID: String
    public let recordRevision: Int
    public let scope: MemoryScope
    public let appointment: AppointmentProjection
    public let documentOnlyWithoutDate:Bool?
    public let support: [FieldSupport]
    public init(recordID: String, recordRevision: Int, scope: MemoryScope,
                appointment:AppointmentProjection,support:[FieldSupport],documentOnlyWithoutDate:Bool=false) {
        self.recordID = recordID; self.recordRevision = recordRevision; self.scope = scope
        self.appointment = appointment; self.support = support;self.documentOnlyWithoutDate=documentOnlyWithoutDate ? true:nil
    }
    public var sources: Set<SourceReference> { Set(support.flatMap(\.anchors).map(\.source)) }
}

public enum MemoryError: Error, Equatable, Sendable {
    case invalidSnapshot, scopeMismatch, needsSynchronization, stalePermit, invalidEvidence
    case unvalidatedRecord, conflictingProjection, staleCorrection, withdrawn
    case staleResult, invalidContext, invalidOrdinal, unsupportedQuery
    case storeAlreadyOpen, closed, corruptStore, unsupportedSchema
    case persistenceFailure(String)
    case incompleteRebuild
}

/// Opaque permits are capabilities against accidental stale asynchronous work,
/// not a security sandbox against a malicious caller in the same process.
public struct SnapshotPermit: Sendable {
    internal let session: UUID
    internal let generation: UInt64
    internal let catalogEpoch: UInt64
}

/// A process-local read of currently permitted originals, including sources
/// without a validated domain record. Only MemoryStore constructs this read.
/// Ranking these observations never admits their semantics as facts.
public struct SourceSearchSnapshot: Sendable {
    public let scope: MemoryScope
    public let sources: [SourceSnapshot]
    public let permit: SnapshotPermit
}

public struct StoredMemory: Codable, Equatable, Sendable {
    public let projection: MemoryProjection
    public let revision: UInt64
}

/// One explicit CAS replacement in an atomic multi-object correction.
public struct ProjectionReplacement: Equatable, Sendable {
    public let projection: MemoryProjection
    public let expectedMemoryRevision: UInt64
    public init(projection: MemoryProjection, expectedMemoryRevision: UInt64) {
        self.projection = projection; self.expectedMemoryRevision = expectedMemoryRevision
    }
}

/// Cache mutations collected by the owning native writer, never model actions.
public enum ProjectionMutation: Equatable, Sendable {
    case insertOrReplay(MemoryProjection)
    case supersede(ProjectionReplacement)
    public var projection: MemoryProjection {
        switch self {
        case .insertOrReplay(let value): return value
        case .supersede(let value): return value.projection
        }
    }
}

public enum ProjectionRebuildSkipReason: String, Codable, Sendable { case withdrawnRecord, forgottenSource }
public struct ProjectionRebuildSkip: Codable, Equatable, Sendable {
    public let recordID: String
    public let reason: ProjectionRebuildSkipReason
}
public struct ProjectionRebuildReport: Codable, Equatable, Sendable {
    public let rows: [StoredMemory]
    public let skipped: [ProjectionRebuildSkip]
}

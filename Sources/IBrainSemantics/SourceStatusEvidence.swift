import Foundation
import IBrain

public enum CancellationEvidenceDisposition:String,Sendable {
    case observedCancellation,correctedCancellation,cancellationNotEstablished
}
public enum PersonalBookingEvidenceDisposition:String,Sendable {
    /// Source records do not certify a current reservation belonging to the user.
    case notEstablishedByPhotoEvidence
}
public struct SourceStatusEvidenceRow:Sendable {
    public let record:StoredMemory
    public let cancellation:CancellationEvidenceDisposition
    /// Exact current field supports, including their observed/correction origin.
    /// Never convert these into an unsupported statement that no notice exists.
    public let statusSupport:[FieldSupport]
    public var provesNotCancelled:Bool {false}
    public var provesNoCancellationNoticePrinted:Bool {false}
}
public struct SourceStatusEvidenceAnswer:Sendable {
    public let requested:Set<RequestedSourceEvidence>
    public let rows:[SourceStatusEvidenceRow]
    public let uncertainMembership:[StoredMemory]
    public let coverage:ExhaustiveAppointmentCoverage
    public var currentPersonalBooking:PersonalBookingEvidenceDisposition? {
        requested.contains(.currentPersonalBooking) ? .notEstablishedByPhotoEvidence:nil
    }
    /// Completed review of admitted records only, never a complete photo reading.
    public var admittedClaimReviewComplete:Bool {coverage.preparedSourceCoverageComplete}
    public var canAssertNoCancellationInPhotos:Bool {false}
    public var personalCalendarComplete:Bool {false}
}
extension ExhaustiveAppointmentAnswer {
    /// Present only after admitting this enclosing answer with its native owner.
    /// A value copied before invalidation does not grant continuing authority.
    public var sourceStatusEvidence:SourceStatusEvidenceAnswer? {
        guard !plan.requestedSourceEvidence.isEmpty else{return nil}
        let rows=matches.map { record in
            let support=record.projection.support.filter{$0.field == .status}
            let disposition=CancellationEvidenceDisposition.classify(record.projection)
            return SourceStatusEvidenceRow(record:record,cancellation:disposition,statusSupport:support)
        }
        return SourceStatusEvidenceAnswer(requested:plan.requestedSourceEvidence,rows:rows,uncertainMembership:uncertain,coverage:coverage)
    }
}

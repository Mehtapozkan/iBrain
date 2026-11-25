import Foundation
import IBrain

/// Membership of one document in the original question's record predicates.
/// A unit may be uncertain even when some individual members match.
public enum UnitEvidenceMemberSelection:String,Sendable {case matching,uncertain,excluded}
public struct UnitSourceStatusEvidenceMember:Sendable {
    public let projection:MemoryProjection
    public let selection:UnitEvidenceMemberSelection
    public let cancellation:CancellationEvidenceDisposition
    public var statusSupport:[FieldSupport] {projection.support.filter{$0.field == .status}}
    public var provesNotCancelled:Bool {false}
    public var provesNoCancellationNoticePrinted:Bool {false}
}
/// All members are retained, including predicate-excluded members of a mixed
/// unit. No member's cancellation is promoted to an event-wide status.
public struct UnitSourceStatusEvidenceRow:Sendable {
    public let unitID:String
    public let membershipUncertain:Bool
    public let conflictingFields:Set<AppointmentField>
    public let members:[UnitSourceStatusEvidenceMember]
}
public struct UnitSourceStatusEvidenceAnswer:Sendable {
    public let requested:Set<RequestedSourceEvidence>
    public let resultUnit:AppointmentResultUnit
    public let rows:[UnitSourceStatusEvidenceRow]
    public let identityResolved:Bool
    public let coverage:ExhaustiveAppointmentCoverage
    public var currentPersonalBooking:PersonalBookingEvidenceDisposition? {
        requested.contains(.currentPersonalBooking) ? .notEstablishedByPhotoEvidence:nil
    }
    /// Review coverage only; this does not certify complete image extraction,
    /// current bookings, or agreement between conflicting member statuses.
    public var admittedClaimReviewComplete:Bool {
        identityResolved && coverage.preparedSourceCoverageComplete && !rows.contains{$0.membershipUncertain}
    }
    public var canAssertNoCancellationInPhotos:Bool {false}
    public var personalCalendarComplete:Bool {false}
}
extension CancellationEvidenceDisposition {
    internal static func classify(_ projection:MemoryProjection)->Self {
        guard projection.appointment.status == .cancelled else{return .cancellationNotEstablished}
        let supports=projection.support.filter{$0.field == .status && !$0.anchors.isEmpty}
        if supports.contains(where:{$0.origin == .domainCorrection}) {return .correctedCancellation}
        if supports.contains(where:{$0.origin == .observed}) {return .observedCancellation}
        return .cancellationNotEstablished
    }
}
internal enum UnitSourceStatusEvidenceProjection {
    static func project(_ answer:ExhaustiveAppointmentAnswer,unit:AppointmentResultUnit,
        matching:[SourceOccurrenceUnit],uncertain:[SourceOccurrenceUnit],identityResolved:Bool)->UnitSourceStatusEvidenceAnswer? {
        guard !answer.plan.requestedSourceEvidence.isEmpty else{return nil}
        let matchedIDs=Set(answer.matches.map{$0.projection.recordID})
        let uncertainIDs=Set(answer.uncertain.map{$0.projection.recordID})
        let uncertainUnits=Set(uncertain.map(\.id))
        let rows=(matching+uncertain).map { unit in
            UnitSourceStatusEvidenceRow(unitID:unit.id,membershipUncertain:uncertainUnits.contains(unit.id),
                conflictingFields:unit.conflictingFields,members:unit.members.map { member in
                    let p=member.projection
                    return UnitSourceStatusEvidenceMember(projection:p,
                        selection:matchedIDs.contains(p.recordID) ? .matching:uncertainIDs.contains(p.recordID) ? .uncertain:.excluded,
                        cancellation:.classify(p))
                })
        }
        return UnitSourceStatusEvidenceAnswer(requested:answer.plan.requestedSourceEvidence,resultUnit:unit,
            rows:rows,identityResolved:identityResolved,coverage:answer.coverage)
    }
}
extension SourceUnitQueryAnswer {
    /// Present only after admitSourceUnitAnswer, alongside the enclosing query,
    /// grouping and relation receipts. This projection grants no photo access.
    public var sourceStatusEvidence:UnitSourceStatusEvidenceAnswer? {
        UnitSourceStatusEvidenceProjection.project(recordAnswer,unit:resultUnit,matching:matchingUnits,
            uncertain:uncertainUnits,identityResolved:identityResolved)
    }
}
extension InventoryUnitQueryAnswer {
    /// Present only after admitInventoryUnitAnswer. All currentness and proof
    /// checks belong to that enclosing answer, including every member source.
    public var sourceStatusEvidence:UnitSourceStatusEvidenceAnswer? {
        UnitSourceStatusEvidenceProjection.project(recordAnswer,unit:resultUnit,matching:matchingUnits,
            uncertain:uncertainUnits,identityResolved:identityResolved)
    }
}

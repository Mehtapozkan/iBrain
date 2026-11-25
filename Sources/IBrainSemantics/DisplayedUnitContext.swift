import Foundation
import IBrain

public struct DisplayedUnitEvidenceRow:Sendable {
    public let unit:SourceOccurrenceUnit
    public let membershipUncertain:Bool
    public let memberSelection:[String:UnitEvidenceMemberSelection]
    public var currentSources:Set<SourceReference> {Set(unit.members.flatMap{$0.projection.sources})}
    /// Inspect each member's claims; there is deliberately no event-wide status.
    public var statusEvidence:UnitSourceStatusEvidenceRow {
        UnitSourceStatusEvidenceRow(unitID:unit.id,membershipUncertain:membershipUncertain,
            conflictingFields:unit.conflictingFields,members:unit.members.map {
                UnitSourceStatusEvidenceMember(projection:$0.projection,
                    selection:memberSelection[$0.projection.recordID]!,cancellation:.classify($0.projection))
            })
    }
}
public struct DisplayedUnitProof:Sendable {
    public let queryReceipt:DecisionReceipt
    public let sourceReceipts:[DecisionReceipt]
    public let localRelationReceipts:[DecisionReceipt]
    public let crossSourceRelationReceipt:DecisionReceipt?
}
/// Process-local context created only from an admitted complete unit answer.
/// The host calls its owner after publication with the order actually displayed.
/// No Codable/public initializer or legacy flat-record conversion is provided.
public struct DisplayedUnitContext:Sendable {
    public let id:UUID
    public let answerRequestID:UUID
    public let originalQuestion:String
    public let originalSubmittedAt:Date
    public let resultUnit:AppointmentResultUnit
    public let orderedRows:[DisplayedUnitEvidenceRow]
    public let identityResolved:Bool
    public let coverage:ExhaustiveAppointmentCoverage
    public let proof:DisplayedUnitProof
    public let bindingSHA256:String
    internal let recordAnswer:ExhaustiveAppointmentAnswer
}
/// An explicit native tap/ordinal or a validated semantic follow-up selects a
/// whole displayed unit. This is evidence handoff, never PhotoKit permission.
public struct DisplayedUnitSelection:Sendable {
    public let contextID:UUID
    public let ordinal:Int
    public let row:DisplayedUnitEvidenceRow
    public let proof:DisplayedUnitProof
    public var currentSources:Set<SourceReference> {row.currentSources}
    public var resultUnit:AppointmentResultUnit {context.resultUnit}
    public var identityResolved:Bool {context.identityResolved}
    public var coverage:ExhaustiveAppointmentCoverage {context.coverage}
    public var currentPersonalBooking:PersonalBookingEvidenceDisposition {.notEstablishedByPhotoEvidence}
    internal let context:DisplayedUnitContext
}
internal enum DisplayedUnitBinding {
    static func data(id:UUID,answer:ExhaustiveAppointmentAnswer,question:String,submittedAt:Date,
        resultUnit:AppointmentResultUnit,rows:[DisplayedUnitEvidenceRow],identityResolved:Bool,proof:DisplayedUnitProof)throws->Data {
        struct Row:Encodable {
            let unitID:String
            let uncertain:Bool
            let members:[MemoryProjection]
            let memberSelection:[String:String]
            let conflictingFields:[String]
        }
        struct Proof:Encodable {
            let query:DecisionReceipt
            let sources:[DecisionReceipt]
            let localRelations:[DecisionReceipt]
            let crossSourceRelation:DecisionReceipt?
        }
        struct State:Encodable {
            let contextID:UUID,answerRequestID:UUID
            let originalQuestion:String,originalSubmittedAt:String,resultUnit:String
            let identityResolved:Bool
            let totalRecords:Int,inspectedRecords:Int
            let rows:[Row]
            let proof:Proof
        }
        let s=State(contextID:id,answerRequestID:answer.requestID,originalQuestion:question,
            originalSubmittedAt:submittedAt.ISO8601Format(),resultUnit:resultUnit.rawValue,
            identityResolved:identityResolved,totalRecords:answer.coverage.totalRecords,
            inspectedRecords:answer.coverage.inspectedRecords,
            rows:rows.map{Row(unitID:$0.unit.id,uncertain:$0.membershipUncertain,
                members:$0.unit.members.map(\.projection),memberSelection:$0.memberSelection.mapValues(\.rawValue),
                conflictingFields:$0.unit.conflictingFields.map(\.rawValue).sorted())},
            proof:Proof(query:proof.queryReceipt,sources:proof.sourceReceipts,localRelations:proof.localRelationReceipts,crossSourceRelation:proof.crossSourceRelationReceipt))
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(s)
    }
}

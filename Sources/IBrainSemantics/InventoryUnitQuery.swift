import Foundation
import IBrain

public struct InventoryUnitQueryAnswer:Sendable {
    public let resultUnit:AppointmentResultUnit
    public let matchingUnits:[SourceOccurrenceUnit]
    public let uncertainUnits:[SourceOccurrenceUnit]
    public let excludedUnits:[SourceOccurrenceUnit]
    public let unresolvedFieldsByUnit:[String:Set<AppointmentField>]
    public let identityResolved:Bool
    public let coverage:ExhaustiveAppointmentCoverage
    public let queryReceipt:DecisionReceipt
    public let sourceReceipts:[DecisionReceipt]
    public let localRelationReceipts:[DecisionReceipt]
    public let crossSourceRelationReceipt:DecisionReceipt?
    public let evidenceBindingSHA256:String
    internal let recordAnswer:ExhaustiveAppointmentAnswer
    public var countLowerBound:Int {identityResolved ? matchingUnits.count:0}
    public var countUpperBound:Int {matchingUnits.count+uncertainUnits.count}
    public var exactCount:Int? {identityResolved && uncertainUnits.isEmpty && coverage.entireAdmittedInventory ? matchingUnits.count:nil}
    public var requestedAnswerComplete:Bool {exactCount != nil && coverage.preparedSourceCoverageComplete && unresolvedFieldsByUnit.isEmpty && recordAnswer.plan.requestedSourceEvidence.isEmpty}
    public var orderedUnits:[SourceOccurrenceUnit] {matchingUnits+uncertainUnits}
    public var orderedMemberRecordIDs:[[String]] {orderedUnits.map{$0.members.map{$0.projection.recordID}}}
}

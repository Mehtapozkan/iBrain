import Foundation
import IBrain

/// An admitted-query candidate over one fully covered source's document groups.
/// No synthesized representative records, persistence or photo-open permission.
public struct SourceUnitQueryAnswer: Sendable {
    public let resultUnit: AppointmentResultUnit
    public let matchingUnits: [SourceOccurrenceUnit]
    public let uncertainUnits: [SourceOccurrenceUnit]
    public let excludedUnits: [SourceOccurrenceUnit]
    public let unresolvedFieldsByUnit: [String:Set<AppointmentField>]
    public let identityResolved: Bool
    public let coverage: ExhaustiveAppointmentCoverage
    public let queryReceipt: DecisionReceipt
    public let groupingReceipt: DecisionReceipt
    public let relationReceipt: DecisionReceipt?
    internal let recordAnswer: ExhaustiveAppointmentAnswer
    public var countLowerBound: Int { identityResolved ? matchingUnits.count : 0 }
    public var countUpperBound: Int { matchingUnits.count+uncertainUnits.count }
    public var exactCount: Int? { identityResolved && uncertainUnits.isEmpty && coverage.entireAdmittedInventory ? matchingUnits.count:nil }
    public var requestedAnswerComplete: Bool {
        exactCount != nil && coverage.preparedSourceCoverageComplete && unresolvedFieldsByUnit.isEmpty && recordAnswer.plan.requestedSourceEvidence.isEmpty
    }
    public var orderedUnits: [SourceOccurrenceUnit] {matchingUnits+uncertainUnits}
    /// Ordinals belong to unit rows. The host binds one row to ALL these native
    /// records/revisions and deduplicates original photo references separately.
    public var orderedMemberRecordIDs: [[String]] {orderedUnits.map{$0.members.map{$0.projection.recordID}}}
}
internal struct UnitQueryEvaluation {
    let matched:[SourceOccurrenceUnit]
    let uncertain:[SourceOccurrenceUnit]
    let excluded:[SourceOccurrenceUnit]
    let gaps:[String:Set<AppointmentField>]
}
internal enum SourceUnitQueryProjection {
    static func project(_ answer:ExhaustiveAppointmentAnswer,request:SourceOccurrenceRequest,proposal:SourceOccurrenceProposal?)throws->SourceUnitQueryAnswer {
        guard let selected=answer.plan.resultUnit,[ExhaustiveAppointmentOperation.list,.count,.sourceEvidence].contains(answer.plan.operation) else {throw SemanticError.unsupportedEvidence}
        let members=try request.checkedMembers(),units:[SourceOccurrenceUnit],identity:Bool
        if selected == .documents {
            let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
            units=try members.map { SourceOccurrenceUnit(id:"document-"+ChoiceTask.hash(try e.encode($0.projection)),members:[$0],conflictingFields:[]) };identity=true
        }else{
            guard let proposal else{throw SemanticError.unresolved("Current complete occurrence proof is required")}
            units=proposal.sameOccurrenceSets;identity=proposal.occurrenceUnits != nil
        }
        let evaluation=evaluate(answer,units:units,identityResolved:identity)
        return SourceUnitQueryAnswer(resultUnit:selected,matchingUnits:evaluation.matched,uncertainUnits:evaluation.uncertain,excludedUnits:evaluation.excluded,unresolvedFieldsByUnit:evaluation.gaps,identityResolved:identity,coverage:answer.coverage,queryReceipt:answer.plan.receipt,groupingReceipt:request.grouping.receipt,relationReceipt:proposal?.receipt,recordAnswer:answer)
    }
    static func evaluate(_ answer:ExhaustiveAppointmentAnswer,units:[SourceOccurrenceUnit],identityResolved:Bool)->UnitQueryEvaluation {
        let matches=Set(answer.matches.map{$0.projection.recordID}),uncertain=Set(answer.uncertain.map{$0.projection.recordID})
        var matched:[SourceOccurrenceUnit]=[],unknown:[SourceOccurrenceUnit]=[],excluded:[SourceOccurrenceUnit]=[],gaps:[String:Set<AppointmentField>]=[:]
        var conditionFields=Set(answer.plan.predicates.compactMap{AppointmentField(rawValue:$0.field.rawValue)})
        if answer.plan.status != "all" {conditionFields.insert(.status)}
        if answer.plan.kind != "all" {conditionFields.insert(.kind)}
        if answer.plan.clock.isRestricted || answer.plan.window.id != "all" {conditionFields.insert(.date)}
        func field(_ detail:RequestedAppointmentDetail)->AppointmentField {
            switch detail {case .localDate,.startClock,.explicitTimeZone:return .date;default:return AppointmentField(rawValue:detail.rawValue)!}
        }
        let requested=Set(answer.plan.requestedDetails.map(field)).union([.title])
        for unit in units {
            let ids=Set(unit.members.map{$0.projection.recordID})
            let conflicted=answer.plan.resultUnit == .occurrences && !unit.conflictingFields.isDisjoint(with:conditionFields)
            // Admission requires a complete scan and current member proof.
            // Unresolved identity cannot revive members the record query
            // already excluded. Condition conflicts still stay uncertain.
            if !conflicted && ids.isDisjoint(with:matches) && ids.isDisjoint(with:uncertain) {
                excluded.append(unit);continue
            }
            if !identityResolved || conflicted || !ids.isDisjoint(with:uncertain) || (!ids.isSubset(of:matches) && !ids.isDisjoint(with:matches)) {unknown.append(unit)}
            else if ids.isSubset(of:matches){matched.append(unit)}
            else{excluded.append(unit);continue}
            var missing=unit.conflictingFields.intersection(requested)
            for id in ids {missing.formUnion((answer.unresolvedDetails[id] ?? []).map(field))}
            if !missing.isEmpty{gaps[unit.id]=missing}
        }
        return UnitQueryEvaluation(matched:matched,uncertain:unknown,excluded:excluded,gaps:gaps)
    }

}

import Foundation
import IBrain

/// One source-local document claim, without cross-photo deduplication. The
/// original unit, member, source/revision and field supports remain intact.
public struct SourceDocumentListRow: Sendable {
    public let unit: SourceOccurrenceUnit
    public let queryMembership: UnitEvidenceMemberSelection
    /// Includes unresolved query conditions as well as requested details.
    public let unresolvedDetails: Set<RequestedAppointmentDetail>
    public let unresolvedFields: Set<AppointmentField>
}

/// Explicit opt-in presentation assessment for a non-count document list.
/// Source-local query membership is independent of cross-photo document
/// identity. This token grants no original-photo access and is not restorable
/// from a DTO. Re-admit immediately before publication; reconstruct after reopen
/// from current authority and the original validated task/receipt evidence.
public struct SourceDocumentListAssessment: Sendable {
    public static let version = "source-document-list-assessment-v1"
    /// Same order and IDs as the original answer's orderedUnits. Do not dedup.
    public let rows: [SourceDocumentListRow]
    public let excludedRows: [SourceDocumentListRow]
    fileprivate let answer: InventoryUnitQueryAnswer

    public var requestedDetails: Set<RequestedAppointmentDetail> { answer.recordAnswer.plan.requestedDetails }
    public var coverage: ExhaustiveAppointmentCoverage { answer.coverage }
    public var queryReceipt: DecisionReceipt { answer.queryReceipt }
    public var evidenceBindingSHA256: String { answer.evidenceBindingSHA256 }
    /// Narrow signals about listed admitted claims only. Empty lists/details
    /// are vacuously resolved; neither signal certifies exhaustive photo reading,
    /// distinct documents, personal bookings or completeness of an answer.
    public var listedMembershipResolved: Bool { rows.allSatisfy { $0.queryMembership != .uncertain } }
    public var listedRequestedFieldsEstablished: Bool {
        rows.allSatisfy { $0.unresolvedDetails.isEmpty && $0.unresolvedFields.isEmpty }
    }
    /// Legacy identity, count and completeness semantics are forwarded unchanged.
    public var identityResolved: Bool { answer.identityResolved }
    public var countLowerBound: Int { answer.countLowerBound }
    public var countUpperBound: Int { answer.countUpperBound }
    public var exactCount: Int? { answer.exactCount }
    public var requestedAnswerComplete: Bool { answer.requestedAnswerComplete }

    fileprivate static func project(_ answer: InventoryUnitQueryAnswer) throws -> Self {
        guard answer.resultUnit == .documents,
              answer.recordAnswer.plan.operation == .list,
              answer.recordAnswer.plan.requestedSourceEvidence.isEmpty,
              answer.coverage.entireAdmittedInventory else { throw SemanticError.unsupportedEvidence }
        let matches = Set(answer.recordAnswer.matches.map { $0.projection.recordID })
        let uncertain = Set(answer.recordAnswer.uncertain.map { $0.projection.recordID })
        func row(_ unit: SourceOccurrenceUnit, excluded: Bool) throws -> SourceDocumentListRow {
            // Only compiler-proven source-local documents qualify. Occurrence
            // sets, unsupported facets and mixed/conflicting members fail closed.
            guard unit.members.count == 1, let member = unit.members.first,
                  member.projection.sources.count == 1, unit.conflictingFields.isEmpty else {
                throw SemanticError.unsupportedEvidence
            }
            let id = member.projection.recordID
            guard !(matches.contains(id) && uncertain.contains(id)) else { throw MemoryError.invalidContext }
            let selection: UnitEvidenceMemberSelection = matches.contains(id) ? .matching : uncertain.contains(id) ? .uncertain : .excluded
            guard excluded == (selection == .excluded) else { throw MemoryError.invalidContext }
            return SourceDocumentListRow(unit: unit, queryMembership: selection,
                unresolvedDetails: answer.recordAnswer.unresolvedDetails[id] ?? [],
                unresolvedFields: answer.unresolvedFieldsByUnit[unit.id] ?? [])
        }
        return try Self(rows: answer.orderedUnits.map { try row($0, excluded: false) },
            excludedRows: answer.excludedUnits.map { try row($0, excluded: true) }, answer: answer)
    }
}

extension ExhaustiveAppointmentSession {
    /// No inference, new query meaning, identity proof or durable state. Uses
    /// the enclosing answer's existing owner/generation/source admission.
    public func sourceDocumentListAssessment(_ answer: InventoryUnitQueryAnswer,
        activeRequestID: UUID) async throws -> SourceDocumentListAssessment {
        let admitted = try await admitInventoryUnitAnswer(answer, activeRequestID: activeRequestID)
        return try SourceDocumentListAssessment.project(admitted)
    }

    @discardableResult public func admitSourceDocumentListAssessment(_ assessment: SourceDocumentListAssessment,
        activeRequestID: UUID) async throws -> SourceDocumentListAssessment {
        _ = try await admitInventoryUnitAnswer(assessment.answer, activeRequestID: activeRequestID)
        return assessment
    }

    /// Bind the actual published row order using the original proof, including
    /// its legacy unit uncertainty AND separate per-member query membership.
    /// Never replace the original unit uncertainty bit with the new assessment.
    public func contextForDisplayedSourceDocumentListAssessment(_ assessment: SourceDocumentListAssessment,
        activeRequestID: UUID, displayedUnitIDs: [String], displayIdentity: UUID? = nil) async throws -> DisplayedUnitContext {
        try await contextForDisplayedInventoryUnitAnswer(assessment.answer, activeRequestID: activeRequestID,
            displayedUnitIDs: displayedUnitIDs, displayIdentity: displayIdentity)
    }
}

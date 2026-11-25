import Foundation
import IBrain

public enum LinkedUnitDetailBasis: String, Codable, Sendable {
    case currentProjection, retainedObservedBeforeCorrection, notEstablished
}
/// Factual output for the explicitly selected ticket/scope. The full current
/// parent remains separately available as proof, never as sibling field output.
public struct LinkedUnitScopedDetail: Codable, Equatable, Sendable {
    public let recordID: String
    public let currentRecordRevision: Int
    public let detail: LinkedUnitDetail
    public let scope: LinkedUnitEvidenceScope
    public let value: String?
    public let support: FieldSupport?
    public let valueRecordRevision: Int?
    public let basis: LinkedUnitDetailBasis
    public let established: Bool
    public let qualification: String?
}
internal enum LinkedMemberFieldReader {
    private static func field(_ detail: LinkedUnitDetail) -> AppointmentField {
        switch detail {
        case .localDate,.startClock,.explicitTimeZone,.yearEvidence: return .date
        case .venueLocation: return .venueAddress
        default: return AppointmentField(rawValue: detail.rawValue)!
        }
    }
    static func read(_ detail: LinkedUnitDetail, current: MemoryProjection, change: SourceRecordChange?, scope: LinkedUnitEvidenceScope) -> LinkedUnitScopedDetail {
        let field = field(detail)
        var source = current, basis = LinkedUnitDetailBasis.currentProjection
        var proof = current.support.first { $0.field == field }
        if scope == .printedOwnSource, proof?.origin != .observed {
            // A latest native before/current comparison is usable only when it
            // still identifies this exact member and the SAME current original.
            // Original quotes remain anchors; the corrected scalar is not text.
            if proof?.origin == .domainCorrection, let change, change.current == current,
               change.previous.recordID == current.recordID, change.previous.scope == current.scope,
               change.previous.sources == current.sources,
               let before = change.previous.support.first(where: { $0.field == field }), before.origin == .observed,
               !before.anchors.isEmpty, before.anchors.allSatisfy({ proof!.anchors.contains($0) && current.sources.contains($0.source) }) {
                source = change.previous; proof = before; basis = .retainedObservedBeforeCorrection
            } else {
                return .init(recordID: current.recordID, currentRecordRevision: current.recordRevision,
                    detail: detail, scope: scope, value: nil, support: nil, valueRecordRevision: nil,
                    basis: .notEstablished, established: false,
                    qualification: "No retained observed value from this ticket's own current source; saved corrections, inferences and sibling facts are not printed evidence.")
            }
        }
        guard let proof, !proof.anchors.isEmpty, proof.anchors.allSatisfy({ current.sources.contains($0.source) }) else {
            return .init(recordID: current.recordID, currentRecordRevision: current.recordRevision,
                detail: detail, scope: scope, value: nil, support: nil, valueRecordRevision: nil,
                basis: .notEstablished, established: false, qualification: "This ticket has no supported saved value for the requested field.")
        }
        let a = source.appointment, d = a.date
        func civil() -> String? {
            guard let y=d.year,let m=d.month,let day=d.day else{return nil}
            return String(format:"%04d-%02d-%02d",y,m,day)
        }
        func clock() -> String? {guard let h=d.hour,let m=d.minute else{return nil};return String(format:"%02d:%02d",h,m)}
        func zone() -> String? {
            if let id=d.timeZoneID{return id}
            guard let offset=d.utcOffsetSeconds else{return nil}
            let n=offset.magnitude
            return "UTC"+(offset<0 ? "-":"+")+String(format:"%02d:%02d:%02d",Int(n/3600),Int((n%3600)/60),Int(n%60))
        }
        let value:String?
        var complete=true
        switch detail {
        case .performer: value=a.performer
        case .provider: value=a.provider
        case .venue: value=a.venue
        case .venueAddress,.venueLocation: value=a.venueAddress
        case .localDate:
            complete=civil() != nil && d.certainty == .explicit && d.captureYearDerivation == nil && d.temporalDerivation == nil
            value=scope == .printedOwnSource ? d.printedDateText ?? (complete ? civil():nil):civil() ?? d.printedDateText
        case .startClock: value=scope == .printedOwnSource ? d.printedTimeText ?? clock():clock() ?? d.printedTimeText;complete=clock() != nil
        case .explicitTimeZone: value=zone()
        case .yearEvidence:
            complete=d.certainty == .explicit && d.captureYearDerivation == nil && d.temporalDerivation == nil
            value=scope == .printedOwnSource && !complete ? nil:d.year.map(String.init)
        }
        let present=value.map{!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty} ?? false
        let established=present && complete && proof.origin != .inferred
        return .init(recordID:current.recordID,currentRecordRevision:current.recordRevision,detail:detail,scope:scope,
            value:present ? value:nil,support:proof,valueRecordRevision:source.recordRevision,basis:basis,
            established:established,qualification:established ? nil:"Requested value is absent, incomplete or inferred in this ticket's own saved evidence; no sibling or linked-place value was substituted.")
    }
}

import Foundation
import IBrain

/// Applies ONE semantically selected text-field proposal over one retained
/// reading. Shared by field interpreters; it does not decide a line's role,
/// join records, change source authority or write memory.
public enum ObservedTextFieldPatch {
    public static func apply(to current:MemoryProjection,source:SourceSnapshot,field:EvidenceTextField,
        observationIDs:[String],extractorVersion:String)throws->MemoryProjection {
        let target=AppointmentField(rawValue:field.rawValue)!
        guard current.scope==source.scope,current.sources==[source.reference],
              Set(source.observations.map(\.id)).count==source.observations.count,
              !observationIDs.isEmpty,observationIDs.count<=64,Set(observationIDs).count==observationIDs.count,
              !extractorVersion.isEmpty,current.support.first(where:{$0.field==target}).map({$0.origin == .observed}) ?? true else{throw SemanticError.unsupportedEvidence}
        for a in current.support.flatMap(\.anchors) {
            guard a.source==source.reference,!a.quote.isEmpty,source.observations.contains(where:{$0.id==a.observationID && ($0.kind == .text ? $0.value.contains(a.quote):$0.value==a.quote)})else{throw SemanticError.unsupportedEvidence}
        }
        let selected=Set(observationIDs),parts=source.observations.filter{selected.contains($0.id)}
        guard parts.count==selected.count,parts.allSatisfy({$0.kind == .text && !$0.value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty})else{throw SemanticError.invalidReceipt}
        let unique=parts.map(\.value).reduce(into:[String]()){if !$0.contains($1){$0.append($1)}}
        let value=unique.joined(separator:field == .performer ? " / ":"\n"),a=current.appointment
        let appointment=AppointmentProjection(title:field == .title ? value:a.title,provider:field == .provider ? value:a.provider,
            venue:field == .venue ? value:a.venue,date:a.date,kind:a.kind,status:a.status,
            performer:field == .performer ? value:a.performer,venueAddress:field == .venueAddress ? value:a.venueAddress)
        let proof=FieldSupport(field:target,anchors:parts.map{EvidenceAnchor(source:source.reference,observationID:$0.id,quote:$0.value)},confidence:0,extractorVersion:extractorVersion)
        return MemoryProjection(recordID:current.recordID,recordRevision:current.recordRevision,scope:current.scope,
            appointment:appointment,support:current.support.filter{$0.field != target}+[proof],documentOnlyWithoutDate:current.documentOnlyWithoutDate ?? false)
    }
}

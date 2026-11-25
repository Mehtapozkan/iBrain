import Foundation
import IBrain

public struct BoundDuplicateSupport:Sendable {
    public let projection:MemoryProjection
    public let permit:SnapshotPermit
}
/// Reuses only observed quotes actually present in a currently read exact-byte
/// duplicate. No fuzzy image/booking identity, missing quote or inferred date
/// may acquire extra support by this mechanism. Host retains record authority.
public enum ExactDuplicateSupport {
    public static func prepare(_ projection:MemoryProjection,duplicate:SourceReference,store:MemoryStore)async throws->BoundDuplicateSupport {
        let permit=try await store.permit(),snapshot=try await store.sourceSearchSnapshot(permit:permit)
        guard projection.scope==snapshot.scope,let duplicateSource=snapshot.sources.first(where:{$0.reference==duplicate}),duplicate.fingerprint.count==64,duplicate.fingerprint.allSatisfy({"0123456789abcdef".contains($0)}),!projection.sources.contains(duplicate)else{throw SemanticError.unsupportedEvidence}
        let sources=Dictionary(uniqueKeysWithValues:snapshot.sources.map{($0.reference,$0)})
        var added=false
        let support=projection.support.map{field->FieldSupport in
            var anchors=field.anchors
            if field.origin == .observed {
                for a in field.anchors where a.source.fingerprint==duplicate.fingerprint && sources[a.source] != nil {
                    guard let original=sources[a.source]?.observations.first(where:{$0.id==a.observationID}),let read=duplicateSource.observations.first(where:{$0.kind==original.kind && ($0.kind == .text ? $0.value.contains(a.quote):$0.value==a.quote)})else{continue}
                    let extra=EvidenceAnchor(source:duplicate,observationID:read.id,quote:a.quote)
                    if !anchors.contains(extra){anchors.append(extra);added=true}
                }
            }
            return FieldSupport(field:field.field,origin:field.origin,anchors:anchors,confidence:field.confidence,extractorVersion:field.extractorVersion)
        }
        guard added else{throw SemanticError.unresolved("no matching current observed quote in duplicate")}
        try await store.validate(permit)
        return BoundDuplicateSupport(projection:MemoryProjection(recordID:projection.recordID,recordRevision:projection.recordRevision,scope:projection.scope,appointment:projection.appointment,support:support,documentOnlyWithoutDate:projection.documentOnlyWithoutDate == true),permit:permit)
    }
    public static func admit(_ proposal:BoundDuplicateSupport,store:MemoryStore)async throws->MemoryProjection{try await store.validate(proposal.permit);return proposal.projection}
}

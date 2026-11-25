import Foundation
import IBrain

/// Retrieves possible originals for semantic inspection. Exact reference
/// equality is never a same-booking verdict, issuer inference or merge grant.
public enum BookingEvidenceRecovery {
    public static func candidates(for incoming:AppointmentCandidate,among candidates:[AppointmentCandidate],store:MemoryStore)async throws->[SourceReference] {
        let snapshot=try await store.sourceSearchSnapshot(permit:store.permit())
        func reference(_ candidate:AppointmentCandidate)->String? {
            guard candidate.disposition == .booking,let anchor=candidate.bookingReferenceEvidence,anchor.source==candidate.source,
                  snapshot.sources.contains(where:{$0.reference==anchor.source && $0.observations.contains{$0.kind == .text && $0.id==anchor.observationID && $0.value==anchor.quote}})else{return nil}
            return anchor.quote.lowercased().split(whereSeparator:\.isWhitespace).joined(separator:" ")
        }
        guard let target=reference(incoming)else{return []}
        let values=Set(candidates.filter{$0.source != incoming.source && reference($0)==target}.map(\.source))
        try await store.validate(snapshot.permit)
        return values.sorted{($0.id,$0.revision,$0.fingerprint)<($1.id,$1.revision,$1.fingerprint)}
    }
}

/// A pure proposal for the owning host after current evidence is forgotten.
/// Keep only already accepted CURRENT values with surviving proof. An older or
/// weaker interpretation cannot introduce a different venue/date/status.
/// MemoryStore still validates source authority and the host's newer domain pin.
public enum CurrentFactRetention {
    public static func proposal(from current:MemoryProjection,candidates:[AppointmentCandidate],remaining:Set<SourceReference>,recordRevision:Int)->MemoryProjection? {
        guard recordRevision>current.recordRevision else{return nil}
        let allowed=remaining.intersection(current.sources)
        let eligible=candidates.filter{allowed.contains($0.source)}
        func same(_ a:AppointmentProjection,_ b:AppointmentProjection,_ field:AppointmentField)->Bool {
            switch field {
            case .title:return a.title==b.title
            case .performer:return a.performer != nil && a.performer==b.performer
            case .venue:return a.venue != nil && a.venue==b.venue
            case .venueAddress:return a.venueAddress != nil && a.venueAddress==b.venueAddress
            case .provider:return a.provider != nil && a.provider==b.provider
            case .kind:return a.kind==b.kind
            case .status:return a.status==b.status
            case .date:return a.date==b.date
            }
        }
        var retained:[AppointmentField:FieldSupport]=[:]
        for field in AppointmentField.allCases {
            if let old=current.support.first(where:{$0.field==field}) {
                let anchors=old.anchors.filter{allowed.contains($0.source)}
                if !anchors.isEmpty,Set(old.anchors.map(\.quote)).isSubset(of:Set(anchors.map(\.quote))) {
                    retained[field]=FieldSupport(field:field,origin:old.origin,anchors:anchors,confidence:old.confidence,extractorVersion:old.extractorVersion);continue
                }
            }
            for candidate in eligible {
                guard let a=candidate.appointment ?? candidate.partialAppointment,same(current.appointment,a,field),
                      let proof=candidate.support.first(where:{$0.field==field}),!proof.anchors.isEmpty,proof.anchors.allSatisfy({allowed.contains($0.source)})else{continue}
                retained[field]=proof;break
            }
        }
        guard retained[.title] != nil,retained[.kind] != nil,retained[.status] != nil else{return nil}
        let old=current.appointment,dated=retained[.date] != nil
        let date=dated ? old.date:EventDate(year:nil,month:nil,day:nil,hour:nil,minute:nil,timeZoneID:nil)
        let a=AppointmentProjection(title:old.title,provider:retained[.provider] != nil ? old.provider:nil,venue:retained[.venue] != nil ? old.venue:nil,date:date,kind:old.kind,status:old.status,performer:retained[.performer] != nil ? old.performer:nil,venueAddress:retained[.venueAddress] != nil ? old.venueAddress:nil)
        return MemoryProjection(recordID:current.recordID,recordRevision:recordRevision,scope:current.scope,appointment:a,support:AppointmentField.allCases.compactMap{retained[$0]},documentOnlyWithoutDate:!dated)
    }
}

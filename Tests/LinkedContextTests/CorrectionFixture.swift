import Foundation
import IBrain

// Authored native provenance fixture; not a model or real-photo extraction.
struct CorrectionFixture {
    let scope=MemoryScope(ownerID:"authored-provenance",namespace:"native-correction")
    let source:SourceSnapshot
    let before:MemoryProjection,corrected:MemoryProjection
    init(sameValue:Bool=false) {
        let scope=MemoryScope(ownerID:"authored-provenance",namespace:"native-correction")
        let ref=SourceReference(id:"photo",revision:1,fingerprint:"AUTHORED-original-unchanged")
        let pairs=[("title","Authored event"),("date","12 November 2026"),("clock","19:30"),("venue","Old Hall"),("kind","Appointment"),("status","Scheduled")]
        source=SourceSnapshot(reference:ref,scope:scope,observations:pairs.map{.init(id:$0.0,value:$0.1)})
        let support=pairs.filter{$0.0 != "clock"}.map{key,value in FieldSupport(field:AppointmentField(rawValue:key)!,anchors:[.init(source:ref,observationID:key,quote:value)]+(key=="date" ? [.init(source:ref,observationID:"clock",quote:"19:30")]:[]),extractorVersion:"AUTHORED-not-model")}
        let appointment=AppointmentProjection(title:"Authored event",venue:"Old Hall",date:EventDate(year:2026,month:11,day:12,hour:19,minute:30,timeZoneID:nil,printedDateText:"12 November 2026",printedTimeText:"19:30"))
        before=MemoryProjection(recordID:"same-appointment",recordRevision:1,scope:scope,appointment:appointment,support:support)
        let updated=AppointmentProjection(title:appointment.title,venue:sameValue ? "Old Hall":"Owner corrected room",date:appointment.date)
        corrected=MemoryProjection(recordID:before.recordID,recordRevision:2,scope:scope,appointment:updated,support:support.map{s in s.field == .venue ? .init(field:s.field,origin:.domainCorrection,anchors:s.anchors,extractorVersion:"AUTHORED-explicit-owner-correction"):s})
    }
    func authority(_ p:MemoryProjection)->AuthoritySnapshot {.init(sources:[source],records:[.init(id:p.recordID,revision:p.recordRevision,sources:p.sources)])}
}

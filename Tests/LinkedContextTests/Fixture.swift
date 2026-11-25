import Foundation
import IBrain
import IBrainSemantics
import IBrainRetrieval

// All data in this file is fictional authored evidence, not model output or
// an assertion that any person booked/attended these appointments.
struct Fixture {
    let scope=MemoryScope(ownerID:"authored-dsc1",namespace:"linked-evidence")
    let sources:[SourceSnapshot]
    let before:MemoryProjection,current:MemoryProjection,other:MemoryProjection
    let world:[WorldMemoryProjection]
    init(wrongBuilding:Bool=false,cycle:Bool=false,sameNameDistractor:Bool=false)throws {
        let scope=MemoryScope(ownerID:"authored-dsc1",namespace:"linked-evidence")
        let spec:[(String,[(String,String)])]=[
            ("photo-old",[("title","Harbor Quartet"),("venue","Gull Hall"),("date","10 November 2026"),("clock","18:30")]),
            ("photo-update",[("title","Harbor Quartet"),("venue","Studio Room"),("date","12 November 2026"),("clock","19:30"),("notice","Harbor Quartet moved from Gull Hall on 10 November to Studio Room on 12 November")]),
            ("photo-venue",[("inside","Studio Room is inside Maritime Centre")]),
            ("photo-address",[("name","Maritime Centre"),("address","27 Pier Road")]),
            ("photo-other",[("title","Lens fitting"),("venue","Optics Desk"),("date","12 November"),("clock","16:00")]),
            ("photo-distractor",[("name",sameNameDistractor ? "Maritime Centre":"Harbor Boat Hire"),("text","Unrelated rental: 12 November 2026 at 19:30; 99 Distant Road")])
        ]
        let sources=try spec.map {id,values in
            let ref=SourceReference(id:id,revision:1,fingerprint:"AUTHORED-"+id)
            let obs=values.map{SourceObservation(id:$0.0,value:$0.1)}
            let read=try SourceReadAssessment(source:ref,coverage:.readable,reader:"AUTHORED_NOT_MODEL",receiptSHA256:String(repeating:"a",count:64),observations:obs)
            return SourceSnapshot(reference:ref,scope:scope,observations:obs,readAssessment:read)
        }
        self.sources=sources
        func source(_ id:String)->SourceSnapshot{sources.first{$0.reference.id==id}!}
        func anchor(_ id:String,_ obs:String,_ quote:String?=nil)->EvidenceAnchor {
            let s=source(id);return .init(source:s.reference,observationID:obs,quote:quote ?? s.observations.first{$0.id==obs}!.value)
        }
        func appointment(_ id:String,_ revision:Int,_ sid:String,_ title:String,_ venue:String,_ year:Int?,_ day:Int,_ h:Int,_ m:Int)->MemoryProjection {
            let a=AppointmentProjection(title:title,venue:venue,date:EventDate(year:year,month:11,day:day,hour:h,minute:m,timeZoneID:nil,printedDateText:source(sid).observations.first{$0.id=="date"}!.value,printedTimeText:source(sid).observations.first{$0.id=="clock"}!.value),kind:.appointment,status:.scheduled)
            let proof:[FieldSupport]=[.init(field:.title,anchors:[anchor(sid,"title")],extractorVersion:"AUTHORED"),.init(field:.venue,anchors:[anchor(sid,"venue")],extractorVersion:"AUTHORED"),.init(field:.date,anchors:[anchor(sid,"date"),anchor(sid,"clock")],extractorVersion:"AUTHORED"),.init(field:.kind,anchors:[anchor(sid,"title")],extractorVersion:"AUTHORED"),.init(field:.status,anchors:[anchor(sid,"title")],extractorVersion:"AUTHORED")]
            return .init(recordID:id,recordRevision:revision,scope:scope,appointment:a,support:proof)
        }
        let before=appointment("appt-A",1,"photo-old","Harbor Quartet","Gull Hall",2026,10,18,30)
        let current=appointment("appt-A",2,"photo-update","Harbor Quartet","Studio Room",2026,12,19,30)
        let other=appointment("appt-B",1,"photo-other","Lens fitting","Optics Desk",nil,12,16,0)
        self.before=before;self.current=current;self.other=other
        var compiled=try AppointmentWorldCompiler.compile(current,identities:.init(eventID:"world-event-A",venueID:"world-studio",revision:2),policy:.typedTemporalValuesV2)
        let studio=compiled.first{$0.recordID=="world-studio"}!
        let edge=WorldClaim(id:"inside",predicate:.locatedAt,value:.entity(wrongBuilding ? "world-distractor":"world-building"),anchors:[anchor("photo-venue","inside")],extractorVersion:"AUTHORED")
        compiled=compiled.filter{$0.recordID != studio.recordID}+[.init(recordID:studio.recordID,recordRevision:studio.recordRevision,scope:scope,kind:.place,claims:studio.claims+[.init(id:"link-name",predicate:.name,value:.text("Studio Room"),anchors:[anchor("photo-venue","inside","Studio Room")],extractorVersion:"AUTHORED"),edge])]
        var building=[WorldClaim(id:"name",predicate:.name,value:.text("Maritime Centre"),anchors:[anchor("photo-address","name")],extractorVersion:"AUTHORED"),WorldClaim(id:"link-name",predicate:.name,value:.text("Maritime Centre"),anchors:[anchor("photo-venue","inside","Maritime Centre")],extractorVersion:"AUTHORED"),WorldClaim(id:"address",predicate:.address,value:.text("27 Pier Road"),anchors:[anchor("photo-address","address")],extractorVersion:"AUTHORED")]
        if cycle{building.append(.init(id:"cycle",predicate:.locatedAt,value:.entity("world-studio"),anchors:[anchor("photo-venue","inside")],extractorVersion:"AUTHORED"))}
        world=compiled+[.init(recordID:"world-building",recordRevision:1,scope:scope,kind:.place,claims:building),.init(recordID:"world-distractor",recordRevision:1,scope:scope,kind:.place,claims:[.init(id:"name",predicate:.name,value:.text(sameNameDistractor ? "Maritime Centre":"Harbor Boat Hire"),anchors:[anchor("photo-distractor","name")],extractorVersion:"AUTHORED"),.init(id:"address",predicate:.address,value:.text("99 Distant Road"),anchors:[anchor("photo-distractor","text","99 Distant Road")],extractorVersion:"AUTHORED")])]
    }
    var authority:AuthoritySnapshot {
        AuthoritySnapshot(sources:sources,records:[current,other].map{.init(id:$0.recordID,revision:$0.recordRevision,sources:$0.sources)}+world.map{.init(id:$0.recordID,revision:$0.recordRevision,sources:$0.sources,recordKind:.worldEntity)})
    }
    func install(directory:URL)async throws->MemoryStore {
        let store=try MemoryStore(directory:directory,scope:scope)
        try await store.synchronize(AuthoritySnapshot(sources:sources,records:[before,other].map{.init(id:$0.recordID,revision:$0.recordRevision,sources:$0.sources)}))
        _=try await store.upsertBatch([before,other],permit:store.permit())
        let captured=try await store.captureRevision(recordID:before.recordID,permit:store.permit())
        try await store.synchronize(authority)
        _=try await store.supersedeWithSourceChange(current,from:captured,permit:store.permit())
        _=try await store.applyWorldBatch(world.map{WorldMemoryWrite($0)},permit:store.permit());return store
    }
    var bindings:[LinkedAppointmentBinding]{[.init(recordID:"appt-A",worldEventID:"world-event-A"),.init(recordID:"appt-B")]}
}

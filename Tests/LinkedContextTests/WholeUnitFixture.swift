import Foundation
import Testing
import IBrain
import IBrainSemantics
import IBrainRetrieval

func occurrenceFixture(day3:Int=20,address3:String="1 Main St",missingVenue:Bool=false,readable:Bool=false,cancelFirst:Bool=false)throws->SourceOccurrenceRequest {
    let ref=SourceReference(id:"three-ticket-photo",revision:1,fingerprint:"pixels"),scope=MemoryScope(ownerID:"authored-dsc1",namespace:"linked-evidence")
    var rows:[SourceObservation]=[],lines:[ObservedLine]=[],members:[SourceOccurrenceMember]=[]
    for i in 1...3 {
        var values=[("title","Example Artist"),("venue","Example Hall"),("date","\(i==3 ? day3:20)-Nov-12 19:30"),("address",i==3 ? address3:"1 Main St")]
        if cancelFirst && i==1 {values.append(("status","CANCELLED"))}
        for (key,value) in values {
            let id="g\(i)-\(key)",region=ObservationRegion(x:0.1,y:Double(4-i)*0.2,width:0.5,height:0.04)
            rows.append(SourceObservation(id:id,value:value));lines.append(ObservedLine(id:id,text:value,confidence:0,region:region))
        }
        let date=EventDate(year:nil,month:11,day:i==3 ? day3:20,hour:19,minute:30,timeZoneID:nil,printedDateText:values[2].1,printedTimeText:"19:30")
        let support=values.filter{!(missingVenue && i==3 && $0.0=="venue")}.map{key,value in FieldSupport(field:key=="address" ? .venueAddress:AppointmentField(rawValue:key)!,anchors:[EvidenceAnchor(source:ref,observationID:"g\(i)-\(key)",quote:value)],extractorVersion:"authored")}
        let p=MemoryProjection(recordID:"ticket\(i)",recordRevision:2,scope:scope,appointment:AppointmentProjection(title:"Example Artist",venue:missingVenue && i==3 ? nil:"Example Hall",date:date,kind:.eventTicket,status:cancelFirst && i==1 ? .cancelled:.scheduled,venueAddress:i==3 ? address3:"1 Main St"),support:support)
        members.append(SourceOccurrenceMember(groupOrdinal:i,projection:p))
    }
    rows.append(SourceObservation(id:"multiple",kind:.visualLabel,value:"reader-reports-multiple-documents"))
    let assessment = readable ? try SourceReadAssessment(source:ref,coverage:.readable,reader:"authored",receiptSHA256:String(repeating:"a",count:64),observations:rows):nil
    let source=SourceSnapshot(reference:ref,scope:scope,observations:rows,readAssessment:assessment)
    let req=VisualGroupingRequest(taskID:"groups",source:source,lines:lines,observationRegions:Dictionary(uniqueKeysWithValues:lines.map{($0.id,$0.region!)}),reportedDocumentCount:3)
    let task=try BoundedVisualSourceGrouper.task(req)
    var answers:[String:ChoiceAnswer]=["count":ChoiceAnswer(choice:"three")]
    for line in lines {answers["observation:"+line.id]=ChoiceAnswer(choice:"object"+String(line.id.dropFirst().prefix(1)))}
    let receipt=DecisionReceipt(provider:"authored",model:"not-inference",requestSHA256:try task.digest(),answers:answers,elapsedSeconds:0)
    if readable {
        members=members.map { m in
            let p=m.projection,anchor=EvidenceAnchor(source:ref,observationID:"g\(m.groupOrdinal)-date",quote:p.appointment.date.printedDateText!)
            let support=p.support.filter{$0.field != .status}.map { f in f.field == .date ? FieldSupport(field:.date,anchors:f.anchors+[EvidenceAnchor(source:ref,observationID:anchor.observationID,quote:"19:30")],extractorVersion:f.extractorVersion):f } + [FieldSupport(field:.kind,anchors:[anchor],extractorVersion:"authored"),FieldSupport(field:.status,anchors:[cancelFirst && m.groupOrdinal==1 ? EvidenceAnchor(source:ref,observationID:"g1-status",quote:"CANCELLED"):anchor],extractorVersion:"authored")]
            return SourceOccurrenceMember(groupOrdinal:m.groupOrdinal,projection:MemoryProjection(recordID:p.recordID,recordRevision:p.recordRevision,scope:p.scope,appointment:p.appointment,support:support))
        }
    }
    return SourceOccurrenceRequest(taskID:"occurrence",source:source,grouping:try BoundedVisualSourceGrouper.compile(req,task:task,receipt:receipt),members:members)
}
func occurrenceReceipt(_ task:ChoiceTask,_ choices:[String:String]=[:])throws->DecisionReceipt {
    var values=task.questions.mapValues{_ in "sameOccurrence"};values.merge(choices){_,n in n}
    return DecisionReceipt(provider:"authored",model:"not-inference",requestSHA256:try task.digest(),answers:values.mapValues{ChoiceAnswer(choice:$0)},elapsedSeconds:0)
}

struct WholeUnitFixture {
    let store:MemoryStore, directory:URL, owner:ExhaustiveAppointmentSession, parentID:UUID, context:DisplayedUnitContext
    let f:Fixture
    init(budget:LinkedContextBudget = .init(),inferredAddress:Bool=false,parentIdentity:UUID?=nil,displayIdentity:UUID?=nil) async throws {
        let f=try Fixture();self.f=f
        let initial=try occurrenceFixture(readable:true)
        let members=initial.members.map { m in
            let p=m.projection
            let support=p.support.map { s in inferredAddress && s.field == .venueAddress ? FieldSupport(field:s.field,origin:.inferred,anchors:s.anchors,extractorVersion:s.extractorVersion):s }
            return SourceOccurrenceMember(groupOrdinal:m.groupOrdinal,projection:MemoryProjection(recordID:p.recordID,recordRevision:p.recordRevision,scope:p.scope,appointment:p.appointment,support:support))
        }
        let grouped=SourceOccurrenceRequest(taskID:initial.taskID,source:initial.source,grouping:initial.grouping,members:members)
        let localTask=try SourceOccurrenceInterpreter.task(grouped),localReceipt=try occurrenceReceipt(localTask)
        let source=f.sources.first{$0.reference.id=="photo-update"}!
        let observation=ObservationRequest(taskID:"AUTHORED-single-current",source:source,lines:source.observations.map{ObservedLine(id:$0.id,text:$0.value,confidence:0)},declaredVisualClues:[],documentPolicy:.documentContentV4,temporalPolicy:.anchoredSpansV9)
        let task=try VisualObservationInterpreter.task(observation,detailPolicy:.componentsV4)
        var choices=task.questions.mapValues { q in q.criteria["unknown"] != nil ? "unknown":q.criteria["other"] != nil ? "other":q.criteria["exclude"] != nil ? "exclude":q.criteria.keys.sorted().first! }
        choices.merge(["document":"booking","documentCount":"one","title":"title","venue":"venue","rawDate":"date","rawTime":"clock","confirmation":"title","kind":"appointment","status":"scheduled","eventTitle_title":"include"]){_,n in n}
        for key in task.questions.keys where key.hasPrefix("temporal_") && task.questions[key]?.criteria["event"] != nil {choices[key]="event"}
        let receipt=DecisionReceipt(provider:"AUTHORED-not-inference",model:"AUTHORED",requestSHA256:try task.digest(),answers:choices.filter{task.questions[$0.key] != nil}.mapValues{ChoiceAnswer(choice:$0)},elapsedSeconds:0)
        let prepared=try InventorySourceUnitCompiler.prepare([.grouped(request:grouped,relationTask:localTask,relationReceipt:localReceipt),.single(.init(initialRequest:observation,initialTask:task,initialReceipt:receipt,projection:f.current))],unit:.occurrences)
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("linked-unit-"+UUID().uuidString);directory=dir
        let store=try MemoryStore(directory:dir,scope:f.scope);self.store=store
        let allSources=f.sources+[grouped.source],before=[f.before]+members.map(\.projection),current=[f.current]+members.map(\.projection)
        try await store.synchronize(AuthoritySnapshot(sources:allSources,records:before.map{.init(id:$0.recordID,revision:$0.recordRevision,sources:$0.sources)}))
        _=try await store.upsertBatch(before,permit:store.permit())
        let captured=try await store.captureRevision(recordID:f.before.recordID,permit:store.permit())
        try await store.synchronize(AuthoritySnapshot(sources:allSources,records:current.map{.init(id:$0.recordID,revision:$0.recordRevision,sources:$0.sources)}+f.world.map{.init(id:$0.recordID,revision:$0.recordRevision,sources:$0.sources,recordKind:.worldEntity)}))
        _=try await store.supersedeWithSourceChange(f.current,from:captured,permit:store.permit())
        _=try await store.applyWorldBatch(f.world.map{WorldMemoryWrite($0)},permit:store.permit())
        let owner=ExhaustiveAppointmentSession(store:store);self.owner=owner;let parent=parentIdentity ?? UUID();parentID=parent
        let input=Self.input(nil,"List all represented events.")
        _=try await owner.prepare(input,requestID:parent,provider:AuthoredInventoryProvider(),planningPolicy:.resultUnitsV4)
        let raw=try await owner.advance(activeRequestID:parent)
        let cross=try #require(try InventoryOccurrenceInterpreter.task(id:"AUTHORED-cross",prepared:prepared))
        let crossReceipt=DecisionReceipt(provider:"AUTHORED-not-inference",model:"AUTHORED",requestSHA256:try cross.digest(),answers:cross.questions.mapValues{_ in ChoiceAnswer(choice:"differentOccurrences")},elapsedSeconds:0)
        let answer=try await owner.inventoryUnitAnswer(raw,prepared:prepared,relationTask:cross,relationReceipt:crossReceipt,activeRequestID:parent)
        let ordered=answer.orderedUnits.sorted{a,b in a.members.count>b.members.count}.map(\.id)
        context=try await owner.contextForDisplayedInventoryUnitAnswer(answer,activeRequestID:parent,displayedUnitIDs:ordered,displayIdentity:displayIdentity)
    }
    static func input(_ context:DisplayedUnitContext?,_ question:String)->EvidenceQuestionInput {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:0)!
        return EvidenceQuestionInput(taskID:"linked-product-question",question:question,now:Date(timeIntervalSince1970:1793640000),calendar:calendar,activeContextID:context?.id)
    }
    var bindings:[LinkedAppointmentBinding]{context.orderedRows.flatMap{$0.unit.members}.map{.init(recordID:$0.projection.recordID,worldEventID:$0.projection.recordID=="appt-A" ? "world-event-A":nil)}}
}
struct AuthoredInventoryProvider:DecisionProvider {
    func decide(_ task:ChoiceTask)async throws->DecisionReceipt {
        var values=["coverage":"supported","operation":"list","window":"all","status":"all","kind":"all","unit":"occurrences"]
        for i in 0..<8{values["clock_\(i)"]="any";for key in ["field","operator","start","end"]{values["\(key)_\(i)"]="none"}}
        for d in RequestedAppointmentDetail.allCases {values["detail_"+d.rawValue]="optional"}
        for f in RequestedSourceEvidence.allCases {values["evidence_"+f.rawValue]="optional"}
        return .init(provider:"AUTHORED-not-inference",model:"AUTHORED",requestSHA256:try task.digest(),answers:task.questions.mapValues{_ in ChoiceAnswer(choice:"unused")}.merging(values.mapValues{ChoiceAnswer(choice:$0)}){_,n in n},elapsedSeconds:0)
    }
}
func authoredLinkedReceipt(_ task:ChoiceTask,operation:String="detailsAndChangesAndCurrentOriginals",target:String="unit_1",details:Set<LinkedUnitDetail>=[.localDate,.startClock,.venueLocation,.venueAddress],changes:String="all",facets:Set<RequestedSourceEvidence>=[])throws->DecisionReceipt {
    var values=["operation":operation,"target":target,"changeFields":changes]
    for d in LinkedUnitDetail.allCases{values["detail_"+d.rawValue]=details.contains(d) ? "required":"optional"}
    for f in RequestedSourceEvidence.allCases{values["evidence_"+f.rawValue]=facets.contains(f) ? "required":"optional"}
    return .init(provider:"AUTHORED-not-inference",model:"AUTHORED",requestSHA256:try task.digest(),answers:values.mapValues{ChoiceAnswer(choice:$0)},elapsedSeconds:0)
}

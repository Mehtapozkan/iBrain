import Foundation
import IBrain
import IBrainSemantics
import IBrainRetrieval

/// Authored two-ticket topology matching Q2's documented failure, not image truth.
struct MemberContractFixture {
    let directory:URL,store:MemoryStore,owner:ExhaustiveAppointmentSession,context:DisplayedUnitContext,parentID:UUID
    let preparedDocuments:PreparedInventoryUnits
    init(corrected:Bool=false,retainHistory:Bool=true,parentIdentity:UUID?=nil,displayIdentity:UUID?=nil)async throws {
        let scope=MemoryScope(ownerID:"authored-member-contract",namespace:"two-tickets"),ref=SourceReference(id:"AUTHORED-two-ticket-photo",revision:1,fingerprint:"AUTHORED-pixels-not-read")
        var observations:[SourceObservation]=[],lines:[ObservedLine]=[],members:[SourceOccurrenceMember]=[]
        for i in 1...2 {
            var values=[("title","SCORPIONS"),("date","16.12.2013"),("clock","20:00 h")]
            if i==2 {values += [("venue","ARENA ARMEEC"),("address","Asen Yordanov Blvd., Sofia")]}
            for (k,v) in values {
                let id="m\(i)-\(k)";observations.append(.init(id:id,value:v));lines.append(.init(id:id,text:v,confidence:0,region:.init(x:0.1,y:Double(i)*0.2,width:0.5,height:0.02)))
            }
            func anchor(_ key:String)->EvidenceAnchor{.init(source:ref,observationID:"m\(i)-"+key,quote:values.first{$0.0==key}!.1)}
            var support:[FieldSupport]=[.init(field:.title,anchors:[anchor("title")],extractorVersion:"AUTHORED"),.init(field:.performer,anchors:[anchor("title")],extractorVersion:"AUTHORED"),.init(field:.date,anchors:[anchor("date"),anchor("clock")],extractorVersion:"AUTHORED"),.init(field:.kind,anchors:[anchor("title")],extractorVersion:"AUTHORED"),.init(field:.status,anchors:[anchor("date")],extractorVersion:"AUTHORED")]
            if i==2 {support += [.init(field:.venue,anchors:[anchor("venue")],extractorVersion:"AUTHORED"),.init(field:.venueAddress,anchors:[anchor("address")],extractorVersion:"AUTHORED")]}
            let p=MemoryProjection(recordID:i==1 ? "z-ticket-first":"a-ticket-second",recordRevision:1,scope:scope,appointment:.init(title:"SCORPIONS",venue:i==2 ? "ARENA ARMEEC":nil,date:.init(year:2013,month:12,day:16,hour:20,minute:0,timeZoneID:nil,printedDateText:"16.12.2013",printedTimeText:"20:00 h"),kind:.eventTicket,status:.scheduled,performer:"SCORPIONS",venueAddress:i==2 ? "Asen Yordanov Blvd., Sofia":nil),support:support)
            members.append(.init(groupOrdinal:i,projection:p))
        }
        observations.append(.init(id:"multiple",kind:.visualLabel,value:"reader-reports-multiple-documents"))
        let assessment=try SourceReadAssessment(source:ref,coverage:.readable,reader:"AUTHORED-NOT-MODEL",receiptSHA256:String(repeating:"a",count:64),observations:observations)
        let source=SourceSnapshot(reference:ref,scope:scope,observations:observations,readAssessment:assessment)
        let groupingInput=VisualGroupingRequest(taskID:"AUTHORED-member-groups",source:source,lines:lines,observationRegions:Dictionary(uniqueKeysWithValues:lines.map{($0.id,$0.region!)}),reportedDocumentCount:2)
        let groupingTask=try BoundedVisualSourceGrouper.task(groupingInput)
        var groupingAnswers=["count":ChoiceAnswer(choice:"two")]
        for line in lines {groupingAnswers["observation:"+line.id] = .init(choice:"object"+String(line.id.dropFirst().prefix(1)))}
        let groupingReceipt=DecisionReceipt(provider:"AUTHORED",model:"NOT-INFERENCE",requestSHA256:try groupingTask.digest(),answers:groupingAnswers,elapsedSeconds:0)
        let grouping=try BoundedVisualSourceGrouper.compile(groupingInput,task:groupingTask,receipt:groupingReceipt)
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("member-contract-"+UUID().uuidString)
        store=try MemoryStore(directory:directory,scope:scope)
        try await store.synchronize(.init(sources:[source],records:members.map{.init(id:$0.projection.recordID,revision:1,sources:$0.projection.sources)}))
        _=try await store.upsertBatch(members.map(\.projection),permit:store.permit())
        if corrected {
            let before=members[1].projection,captured=try await store.captureRevision(recordID:before.recordID,permit:store.permit())
            var support=before.support;let old=support.first{$0.field == .venue}!
            support.removeAll{$0.field == .venue};support.append(.init(field:.venue,origin:.domainCorrection,anchors:old.anchors,extractorVersion:"AUTHORED-owner-correction"))
            let after=MemoryProjection(recordID:before.recordID,recordRevision:2,scope:scope,appointment:.init(title:before.appointment.title,venue:"Owner Room",date:before.appointment.date,kind:.eventTicket,status:.scheduled,performer:"SCORPIONS",venueAddress:before.appointment.venueAddress),support:support)
            members[1] = .init(groupOrdinal:2,projection:after)
            try await store.synchronize(.init(sources:[source],records:members.map{.init(id:$0.projection.recordID,revision:$0.projection.recordRevision,sources:$0.projection.sources)}))
            if retainHistory {_=try await store.supersedeWithSourceChange(after,from:captured,permit:store.permit())}
            else {let revision=try await store.lastMemoryRevision(recordID:after.recordID,permit:store.permit());_=try await store.supersede(after,expectedMemoryRevision:revision!,permit:store.permit())}
        }
        let request=SourceOccurrenceRequest(taskID:"AUTHORED-member-relations",source:source,grouping:grouping,members:members,contextPolicy:.jointIdentityV3)
        let task=try SourceOccurrenceInterpreter.task(request)
        let receipt=DecisionReceipt(provider:"AUTHORED-native-control-NOT-MODEL",model:"AUTHORED",requestSHA256:try task.digest(),answers:task.questions.mapValues{_ in .init(choice:corrected ? "unclear":"sameOccurrence")},elapsedSeconds:0)
        let units=try InventorySourceUnitCompiler.prepare([.grouped(request:request,relationTask:task,relationReceipt:receipt)],unit:.occurrences)
        preparedDocuments=try InventorySourceUnitCompiler.prepare([.grouped(request:request,relationTask:nil,relationReceipt:nil)],unit:.documents)
        owner=ExhaustiveAppointmentSession(store:store);parentID=parentIdentity ?? UUID()
        _=try await owner.prepare(Self.input(nil,"List every concert in these photos."),requestID:parentID,provider:AuthoredInventoryProvider(),planningPolicy:.resultUnitsV4)
        let records=try await owner.advance(activeRequestID:parentID)
        let answer=try await owner.inventoryUnitAnswer(records,prepared:units,activeRequestID:parentID)
        let order=answer.orderedUnits.sorted{$0.members.first!.projection.recordID < $1.members.first!.projection.recordID}.map(\.id)
        context=try await owner.contextForDisplayedInventoryUnitAnswer(answer,activeRequestID:parentID,displayedUnitIDs:order,displayIdentity:displayIdentity)
    }
    static func input(_ context:DisplayedUnitContext?,_ question:String)->EvidenceQuestionInput {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:0)!
        return .init(taskID:"member-question",question:question,now:Date(timeIntervalSince1970:1793640000),calendar:calendar,activeContextID:context?.id)
    }
    func close()async {await store.close();try? FileManager.default.removeItem(at:directory)}
}

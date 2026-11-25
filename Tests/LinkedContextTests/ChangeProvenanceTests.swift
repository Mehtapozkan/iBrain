import Foundation
import Testing
@testable import IBrain
import IBrainSemantics
import IBrainRetrieval

@Test func actualNativeCorrectionRetainsOriginQuoteAndReopensWithoutPhotoClaim()async throws {
    let f=CorrectionFixture(),dir=FileManager.default.temporaryDirectory.appendingPathComponent("change-origin-"+UUID().uuidString)
    let store=try MemoryStore(directory:dir,scope:f.scope)
    try await store.synchronize(f.authority(f.before));_=try await store.upsert(f.before,permit:store.permit())
    let linked=try LinkedAppointmentContextSession(store:store),id=UUID(),old=try await linked.prepare(bindings:[.init(recordID:f.before.recordID)],requestID:id)
    let captured=try await store.captureRevision(recordID:f.before.recordID,permit:store.permit())
    try await store.synchronize(f.authority(f.corrected))
    let change=try await store.supersedeWithSourceChange(f.corrected,from:captured,permit:store.permit()),explanation=change.explanation()
    #expect(explanation.text.contains("[owner correction]") && explanation.text.hasPrefix("According to the retained evidence:"))
    let field=try #require(explanation.fields.first{$0.field == .venue})
    #expect(field.previousSupport?.origin == .observed && field.currentSupport?.origin == .domainCorrection)
    #expect(field.currentEvidence.first?.quote=="Old Hall" && field.currentValue=="Owner corrected room" && field.currentEvidence.first?.source==f.source.reference)
    do{_=try await linked.expand(old.summaries[0].reference,in:old,activeRequestID:id);Issue.record("Pre-correction reference admitted")}catch{}
    let current=try await linked.prepare(bindings:[.init(recordID:f.before.recordID)],requestID:UUID()),ref=try #require(current.summaries[0].nextHops.first{$0.kind == .retainedChange})
    let expanded=try await linked.expand(ref,in:current,activeRequestID:current.requestID)
    guard case .change(let result)=expanded.payload else{Issue.record("Missing change explanation");return}
    #expect(result==explanation);await store.close()
    let reopened=try MemoryStore(directory:dir,scope:f.scope);try await reopened.synchronize(f.authority(f.corrected))
    let restored=try await reopened.sourceChangeSnapshot(permit:reopened.permit())
    #expect(restored.first?.explanation()==explanation)
    await reopened.close();try? FileManager.default.removeItem(at:dir)
}
@Test func originOnlyChangeIsRetainedWithoutInventingDifferentPrintedValue()throws {
    let f=CorrectionFixture(sameValue:true),c=SourceRecordChange(previous:f.before,current:f.corrected),e=c.explanation()
    let field=try #require(e.fields.first{$0.field == .venue})
    #expect(field.previousValue==field.currentValue && field.previousSupport?.origin == .observed && field.currentSupport?.origin == .domainCorrection)
    #expect(e.text.contains("Old Hall [owner correction]") && !e.text.hasPrefix("According to the retained photos:"))
}
private func temporalProjection(_ p:MemoryProjection,certainty:DateCertainty,offset:Int?,hour:Int,origin:FactOrigin = .observed)->MemoryProjection {
    let d=p.appointment.date,date=EventDate(year:d.year,month:d.month,day:d.day,hour:hour,minute:d.minute,timeZoneID:nil,utcOffsetSeconds:offset,certainty:certainty,printedDateText:d.printedDateText,printedTimeText:d.printedTimeText)
    return .init(recordID:p.recordID,recordRevision:p.recordRevision+1,scope:p.scope,appointment:.init(title:p.appointment.title,venue:p.appointment.venue,date:date),support:p.support.map{s in s.field == .date ? .init(field:s.field,origin:origin,anchors:s.anchors,extractorVersion:s.extractorVersion):s})
}
// The next two are explanation-format controls, not admission of inferred or
// newly extracted records; the native store control above covers real admission.
@Test func inferredAndConflictingDateValuesNeverBecomeUnqualifiedPhotoClaims()throws {
    let f=CorrectionFixture()
    for certainty in [DateCertainty.inferred,.conflicting] {
        let p=temporalProjection(f.before,certainty:certainty,offset:nil,hour:20,origin:certainty == .inferred ? .inferred:.observed)
        let e=SourceRecordChange(previous:f.before,current:p).explanation(fields:[.date])
        #expect(e.text.hasPrefix("According to the retained evidence:"))
        #expect(e.text.contains(certainty == .inferred ? "includes inferred date/time":"conflicting date/time evidence"))
        #expect(e.fields[0].currentSupport?.origin == (certainty == .inferred ? .inferred:.observed))
    }
}
@Test func explicitNumericOffsetIsRenderedInsteadOfUnknownTimezone()throws {
    let f=CorrectionFixture()
    for (offset,text) in [(7200,"UTC+02:00"),(-12600,"UTC-03:30"),(19815,"UTC+05:30:15")] {
        let p=temporalProjection(f.before,certainty:.explicit,offset:offset,hour:20)
        let e=SourceRecordChange(previous:f.before,current:p).explanation(fields:[.date])
        #expect(e.text.contains(text) && e.text.contains("20:30"))
    }
}
@Test func olderExplanationDTOStillDecodesWithoutInventingObservedOrigin()throws {
    let raw=Data("{\"field\":\"venue\",\"previousValue\":\"Old Hall\",\"currentValue\":\"New Hall\",\"previousEvidence\":[],\"currentEvidence\":[]}".utf8)
    let decoded=try JSONDecoder().decode(SupportedFieldChange.self,from:raw)
    #expect(decoded.previousSupport==nil && decoded.currentSupport==nil)
    let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
    let object=try #require(try JSONSerialization.jsonObject(with:e.encode(decoded))as?[String:Any])
    #expect(object["previousSupport"]==nil && object["currentSupport"]==nil && decoded.currentValue=="New Hall")
}
@Test func unchangedObservedWordingAndRequestedSubsetStayExact()throws {
    let f=try Fixture(),c=SourceRecordChange(previous:f.before,current:f.current),e=c.explanation(fields:[.venue])
    #expect(e.text=="According to the retained photos: Venue: Gull Hall → Studio Room")
    #expect(e.fields.count==1 && e.fields[0].previousSupport?.origin == .observed && e.fields[0].currentSupport?.origin == .observed)
    #expect(c.explanation(fields:[.status]).text=="The retained source revisions show the same requested supported fields.")
}

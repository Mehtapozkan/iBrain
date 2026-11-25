import Foundation
import Testing
import IBrain
import IBrainSemantics
import IBrainRetrieval

func unifiedAuthored(_ f:WholeUnitFixture,_ p:PreparedLinkedUnitQuestion,route:String="contextual")async throws->(PreparedProductQuestion,DecisionReceipt,CompiledProductQuestion) {
    let state=try JSONSerialization.jsonObject(with:Data(p.task.state.utf8)) as! [String:Any]
    let input=WholeUnitFixture.input(f.context,state["latestQuestion"] as! String)
    let inventory=try ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4)
    let parent=try ProductQuestionPlanner.prepare(taskID:"linked-unified-parent",inventory:inventory,contextual:p.task,permit:await f.store.permit())
    var answers=parent.task.questions.mapValues{_ in ChoiceAnswer(choice:ProductQuestionPlanner.inactive)}
    answers["route"]=ChoiceAnswer(choice:route)
    if route=="contextual"{for(k,v)in try authoredLinkedReceipt(p.task).answers{answers["contextual__"+k]=v}}
    let receipt=DecisionReceipt(provider:"AUTHORED-unified-not-inference",model:"AUTHORED",requestSHA256:try parent.task.digest(),answers:answers,elapsedSeconds:0)
    return(parent,receipt,try ProductQuestionPlanner.compile(receipt,for:parent))
}
@Test func unifiedProductDecisionKeepsActualParentAndNeverFabricatesChild()async throws {
    let f=try await WholeUnitFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    let p=try await s.prepare(WholeUnitFixture.input(f.context,"For the second event give current details, location and all changes, and open originals."),context:f.context,activeAnswerRequestID:f.parentID,requestID:UUID(),bindings:f.bindings)
    let (parent,receipt,decision)=try await unifiedAuthored(f,p)
    #expect(parent.task.version==ProductQuestionPlanner.deterministicLinkedUnitContextVersion)
    let a=try await s.complete(productDecision:decision,for:p,activeRequestID:p.requestID)
    #expect(a.rows[0].members==[f.f.current] && a.plan.originalReceipt.requestSHA256==receipt.requestSHA256)
    #expect(a.plan.originalReceipt.answers["route"]?.choice=="contextual" && a.plan.originalReceipt.answers["operation"]==nil)
    #expect(a.currentOriginalSelections.count==1 && a.rows[0].gaps.isEmpty)
    _=try await s.admit(a,activeRequestID:p.requestID)
    do{_=try await s.complete(receipt,for:p,activeRequestID:p.requestID);Issue.record("Unified receipt rebound as standalone child")}catch{}
    let (_,_,inactive)=try await unifiedAuthored(f,p,route:"unsupported")
    do{_=try await s.complete(productDecision:inactive,for:p,activeRequestID:p.requestID);Issue.record("Inactive product branch executed")}catch{}
    await f.store.close();try? FileManager.default.removeItem(at:f.directory)
}
@Test func unifiedClockInactiveBranchAndExactChildAreBound()async throws {
    let f=try await WholeUnitFixture(),s=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
    let input=WholeUnitFixture.input(f.context,"For the second event explain what changed."),p=try await s.prepare(input,context:f.context,activeAnswerRequestID:f.parentID,requestID:UUID(),bindings:f.bindings)
    var calendar=input.calendar;calendar.minimumDaysInFirstWeek=calendar.minimumDaysInFirstWeek==1 ? 4:1
    let wrong=EvidenceQuestionInput(taskID:input.taskID,question:input.question,now:input.now,calendar:calendar)
    let permit=try await f.store.permit()
    #expect(throws:(any Error).self){try CompactProductQueryPlanner.prepare(taskID:"not-compact-v1",inventory:ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),contextual:p.task,permit:permit)}
    #expect(throws:(any Error).self){try ProductQuestionPlanner.prepare(taskID:"wrong-calendar",inventory:ExhaustiveAppointmentPlanner.task(wrong,policy:.resultUnitsV4),contextual:p.task,permit:permit)}
    let (parent,receipt,decision)=try await unifiedAuthored(f,p)
    var answers=receipt.answers;answers["inventory__operation"]=ChoiceAnswer(choice:"list")
    let bad=DecisionReceipt(provider:receipt.provider,model:receipt.model,requestSHA256:receipt.requestSHA256,answers:answers,elapsedSeconds:0)
    #expect(throws:(any Error).self){try ProductQuestionPlanner.compile(bad,for:parent)}
    let other=try await s.prepare(WholeUnitFixture.input(f.context,"For the FIRST event explain what changed."),context:f.context,activeAnswerRequestID:f.parentID,requestID:UUID(),bindings:f.bindings)
    do{_=try await s.complete(productDecision:decision,for:other,activeRequestID:other.requestID);Issue.record("Different child question executed")}catch{}
    await f.store.close();try? FileManager.default.removeItem(at:f.directory)
}
@Test func capturedLegacyTaskAndReceiptBytesStayExactWithOptionalExtension()async throws {
    let f=try await WholeUnitFixture()
    let url=try #require(Bundle.module.url(forResource:"legacy-product-task",withExtension:"json",subdirectory:"Fixtures"))
    let frozen=try JSONDecoder().decode(ChoiceTask.self,from:Data(contentsOf:url)),root=try JSONSerialization.jsonObject(with:Data(frozen.state.utf8)) as! [String:Any]
    let inventory=(root["branches"] as! [String:Any])["inventory"] as! [String:Any],state=inventory["state"] as! [String:Any]
    var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:state["calendarZone"] as! String)!;calendar.firstWeekday=state["firstWeekday"] as! Int;calendar.minimumDaysInFirstWeek=state["minimumDaysInFirstWeek"] as! Int
    let now=try #require(ISO8601DateFormatter().date(from:state["now"] as! String))
    let input=EvidenceQuestionInput(taskID:inventory["taskID"] as! String,question:state["question"] as! String,now:now,calendar:calendar,policy:.completeV9,inferredDatePolicy:.labelledTemporalContext)
    let prepared=try ProductQuestionPlanner.prepare(taskID:frozen.id,inventory:ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),contextual:nil,permit:await f.store.permit())
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
    #expect(try encoder.encode(prepared.task)==encoder.encode(frozen))
    let legacy=DecisionReceipt(provider:"authored",model:"none",requestSHA256:"digest",answers:["a":ChoiceAnswer(choice:"yes")],elapsedSeconds:0)
    #expect(String(decoding:try encoder.encode(legacy),as:UTF8.self)=="{\"answers\":{\"a\":{\"choice\":\"yes\"}},\"elapsedSeconds\":0,\"model\":\"none\",\"provider\":\"authored\",\"requestSHA256\":\"digest\"}")
    await f.store.close();try? FileManager.default.removeItem(at:f.directory)
}

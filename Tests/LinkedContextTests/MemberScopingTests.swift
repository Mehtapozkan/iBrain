import Foundation
import Testing
import IBrain
import IBrainSemantics
import IBrainRetrieval

private let failedInventoryWording="List all the photographed concerts still held in Pin, including the older dates."
private func scopingParent(_ f:MemberContractFixture,withContext:Bool)async throws->PreparedCompactProductQuestion {
    let input=MemberContractFixture.input(withContext ? f.context:nil,failedInventoryWording)
    let task:ChoiceTask?
    if withContext {
        let session=try LinkedUnitQuestionSession(store:f.store,unitOwner:f.owner)
        task=try await session.prepare(input,context:f.context,activeAnswerRequestID:f.parentID,requestID:UUID(),policy:.memberDetailsV3).task
    } else {task=nil}
    return try CompactProductQueryPlanner.prepare(taskID:"scoping-minor",inventory:ExhaustiveAppointmentPlanner.task(input,policy:.resultUnitsV4),contextual:task,permit:await f.store.permit(),contract:.memberDetailsV3)
}
private func scopingVariants(_ task:CompactProductQueryTask)throws->[[String:Any]] {
    let schema=try JSONSerialization.jsonObject(with:Data(task.responseSchemaJSON.utf8)) as! [String:Any]
    return ((schema["properties"] as! [String:Any])["decision"] as! [String:Any])["anyOf"] as! [[String:Any]]
}
private func variantKind(_ variant:[String:Any])->String {
    let p=variant["properties"] as! [String:Any]
    return (p["kind"] as! [String:Any])["enum"] as! [String] == ["inventory"] ? "inventory":((p["kind"] as! [String:Any])["enum"] as! [String])[0]
}
private func scopingReceipt(_ task:CompactProductQueryTask,_ decision:[String:Any])throws->CompactProductQueryReceipt {
    let data=try JSONSerialization.data(withJSONObject:["decision":decision],options:[.sortedKeys,.withoutEscapingSlashes])
    return .init(provider:"AUTHORED-SCOPING-NOT-MODEL",model:"AUTHORED",requestSHA256:try task.digest(),outputJSON:String(decoding:data,as:UTF8.self),elapsedSeconds:0)
}
@Test func memberScopingAbsentParentOffersOnlyInventoryAndNoExecutionFields()async throws {
    let f=try await MemberContractFixture(),p=try await scopingParent(f,withContext:false)
    #expect(p.task.version=="photo-product-query-compact-v3.1-member-details")
    #expect(!p.task.instructions.contains("MEMBER CONTRACT:") && !p.task.instructions.contains("opt-in contextual branch"))
    #expect(!p.task.instructions.contains("unit_0_member_0") && !p.task.instructions.contains("evidenceScope"))
    let state=try JSONSerialization.jsonObject(with:Data(p.task.state.utf8)) as! [String:Any],prepared=state["preparedState"] as! [String:Any],branches=prepared["branches"] as! [String:Any]
    #expect(Set(branches.keys)==["inventory"] && !(prepared["authority"] as! String).contains("Both branches"))
    #expect(p.task.state.contains(failedInventoryWording))
    for variant in try scopingVariants(p.task){let fields=variant["properties"] as! [String:Any];#expect(fields["evidenceScope"]==nil && variantKind(variant) != "contextual")}
    let output:[String:Any]=["kind":"inventory","operation":"list","unit":"occurrences","window":"all","status":"all","documentKind":"eventTicket","clockBounds":[],"predicates":[],"requestedDetails":["localDate"],"evidenceFacets":[]]
    let d=try CompactProductQueryPlanner.compile(scopingReceipt(p.task,output),for:p)
    let plan=try ExhaustiveAppointmentPlanner.compile(compactDecision:d,input:MemberContractFixture.input(nil,failedInventoryWording),policy:.resultUnitsV4)
    #expect(d.route == .inventory && plan.requestedDetails==[.localDate] && plan.question==failedInventoryWording)
    if let path=ProcessInfo.processInfo.environment["IBRAIN_SCOPING_ARTIFACT_DIR"] {
        let dir=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        try encoder.encode(p.task).write(to:dir.appendingPathComponent("NO-PARENT-TASK.json"))
        try encoder.encode(scopingReceipt(p.task,output)).write(to:dir.appendingPathComponent("AUTHORED-INVENTORY-RECEIPT.json"))
    }
    await f.close()
}
@Test func memberScopingPresentParentRequiresScopeOnlyForContextualPayload()async throws {
    let f=try await MemberContractFixture(),p=try await scopingParent(f,withContext:true)
    #expect(p.task.instructions.contains("For kind=contextual ONLY"))
    #expect(p.task.instructions.contains("Inventory and no-execution payloads must omit evidenceScope"))
    #expect(!p.task.instructions.contains("evidenceScope is REQUIRED:") && !p.task.instructions.contains("contextual evidenceScope:"))
    if let path=ProcessInfo.processInfo.environment["IBRAIN_SCOPING_ARTIFACT_DIR"] {
        let dir=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        try encoder.encode(p.task).write(to:dir.appendingPathComponent("WITH-PARENT-TASK.json"))
    }
    for variant in try scopingVariants(p.task) {
        let fields=variant["properties"] as! [String:Any],required=variant["required"] as! [String]
        if variantKind(variant)=="contextual" {#expect(fields["evidenceScope"] != nil && required.contains("evidenceScope"))}
        else {#expect(fields["evidenceScope"]==nil && !required.contains("evidenceScope"))}
    }
    for kind in ["clarify","unknown","unsupported"] {
        let good=try scopingReceipt(p.task,["kind":kind,"reason":"meaning"])
        #expect(try CompactProductQueryPlanner.compile(good,for:p).route.rawValue==kind)
        let bad=try scopingReceipt(p.task,["kind":kind,"reason":"meaning","evidenceScope":"currentSaved"])
        #expect(throws:(any Error).self){try CompactProductQueryPlanner.compile(bad,for:p)}
    }
    await f.close()
}
@Test func memberScopingOldV3TaskAndReceiptStayArchivedNotRebound()async throws {
    let url=try #require(Bundle.module.url(forResource:"ARCHIVED-V3-COMPACT-PARENT-TASK",withExtension:"json",subdirectory:"Fixtures"))
    let task=try JSONDecoder().decode(CompactProductQueryTask.self,from:Data(contentsOf:url))
    let receiptURL=try #require(Bundle.module.url(forResource:"ARCHIVED-V3-AUTHORED-PARENT-RECEIPT",withExtension:"json",subdirectory:"Fixtures"))
    let receipt=try JSONDecoder().decode(CompactProductQueryReceipt.self,from:Data(contentsOf:receiptURL))
    #expect(task.version=="photo-product-query-compact-v3-member-details")
    #expect(throws:(any Error).self){try receipt.validate(for:task)}
    let f=try await MemberContractFixture(),p=try await scopingParent(f,withContext:true)
    #expect(throws:(any Error).self){try CompactProductQueryPlanner.compile(receipt,for:p)}
    await f.close()
}

import Foundation
import Testing
import IBrain
import IBrainSemantics
import IBrainRetrieval

@Test func savedLocationBaselineReproducesOwnAddressHeldAndCapturesOldWires() async throws {
    let f = try await DocumentIdentityFixture(sourceCount: 1)
    let context = try await f.owner.contextForDisplayedInventoryUnitAnswer(f.answer, activeRequestID: f.requestID, displayedUnitIDs: f.answer.orderedUnits.map(\.id))
    let s = try LinkedUnitQuestionSession(store: f.store, unitOwner: f.owner)
    let p = try await s.prepare(WholeUnitFixture.input(context,"Where is the saved appointment?"), context: context, activeAnswerRequestID: f.requestID, requestID: UUID(), policy: .memberDetailsV3)
    var choices = ["operation":"details", "target":"unit_0", "changeFields":"none", "evidenceScope":"currentSaved"]
    for d in LinkedUnitDetail.allCases { choices["detail_"+d.rawValue] = d == .venueLocation ? "required":"optional" }
    for v in RequestedSourceEvidence.allCases { choices["evidence_"+v.rawValue]="optional" }
    let r = DecisionReceipt(provider:"AUTHORED-OFFLINE-CONTROL",model:"NO-INFERENCE",requestSHA256:try p.task.digest(),answers:choices.mapValues{.init(choice:$0)},elapsedSeconds:0)
    let a = try await s.complete(r,for:p,activeRequestID:p.requestID)
    #expect(a.rows[0].members[0].appointment.venueAddress == "AUTHORED 31 Main Street")
    #expect(a.rows[0].gaps.contains{$0.field=="venueLocation" && $0.reason=="No proven current location link to expand."})
    #expect(!a.allRequestedValuesEstablished && a.rows[0].scopedDetails==nil)
    await f.close()
    let c = try await CalendarDefaultsFixture()
    var tasks = try c.oldTasks()
    for present in [true,false] {
        tasks["calendar-\(present)"] = try CompactProductQueryPlanner.prepareCalendarDefaults(taskID:"AUTHORED-wire-freeze",inventory:c.inventory,contextual:present ? c.child.task:nil,sources:c.sources).task
        tasks["photo-calendar-\(present)"] = try CompactProductQueryPlanner.preparePhotoCalendarDefaults(taskID:"AUTHORED-wire-freeze",inventory:c.inventory,contextual:present ? c.child.task:nil,sources:c.sources).task
    }
    if let dir=ProcessInfo.processInfo.environment["IBRAIN_LOCATION_CAPTURE"] {
        let u=URL(fileURLWithPath:dir);try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true)
        for (name,task) in tasks { try calendarCanonical(task).write(to:u.appendingPathComponent(name+".json")) }
        try calendarCanonical(c.child.task).write(to:u.appendingPathComponent("native-member.json"))
    }
    if let dir=ProcessInfo.processInfo.environment["IBRAIN_LOCATION_COMPARE"] {
        let u=URL(fileURLWithPath:dir)
        for (name,task) in tasks { #expect(try calendarCanonical(task)==Data(contentsOf:u.appendingPathComponent(name+".json"))) }
        #expect(try calendarCanonical(c.child.task)==Data(contentsOf:u.appendingPathComponent("native-member.json")))
    }
    await c.close()
}

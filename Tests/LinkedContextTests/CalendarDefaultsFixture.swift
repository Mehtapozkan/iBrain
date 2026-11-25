import Foundation
import IBrain
import IBrainSemantics
import IBrainRetrieval

/// Fully authored native context. No image, actual failed case or model replay.
struct CalendarDefaultsFixture {
    let member: MemberContractFixture
    let linked: LinkedUnitQuestionSession
    let input: EvidenceQuestionInput
    let child: PreparedLinkedUnitQuestion
    let inventory: ChoiceTask
    let sources: SourceSearchSnapshot

    init(question: String = "List the appointments this week with addresses.") async throws {
        member = try await MemberContractFixture(
            parentIdentity: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            displayIdentity: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        linked = try LinkedUnitQuestionSession(store: member.store, unitOwner: member.owner)
        input = MemberContractFixture.input(member.context, question)
        child = try await linked.prepare(input, context: member.context, activeAnswerRequestID: member.parentID,
            requestID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, policy: .memberDetailsV3)
        inventory = try ExhaustiveAppointmentPlanner.task(input, policy: .resultUnitsV4)
        sources = try await member.store.sourceSearchSnapshot(permit: member.store.permit())
    }

    func oldTasks() throws -> [String: CompactProductQueryTask] {
        ["member-parent": try CompactProductQueryPlanner.prepare(taskID: "AUTHORED-calendar-parent", inventory: inventory,
            contextual: child.task, permit: sources.permit, contract: .memberDetailsV3).task,
         "member-absent": try CompactProductQueryPlanner.prepare(taskID: "AUTHORED-calendar-parent", inventory: inventory,
            contextual: nil, permit: sources.permit, contract: .memberDetailsV3).task,
         "source-scope": try CompactProductQueryPlanner.prepareCurrentSourceScope(taskID: "AUTHORED-calendar-parent", inventory: inventory, sources: sources).task,
         "legacy-default": try CompactProductQueryPlanner.prepare(taskID: "AUTHORED-calendar-parent", inventory: inventory,
            contextual: nil, permit: sources.permit).task]
    }

    func close() async { await member.close() }
}

func calendarCanonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

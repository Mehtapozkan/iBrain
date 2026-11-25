import Foundation
import Testing
import IBrain
import IBrainSemantics
import IBrainRetrieval

@Test func independentNativeReconstructionHasIdenticalSemanticTaskWithoutReferenceAuthority() async throws {
    let parent = UUID(), display = UUID(), request = UUID()
    let phone = try await WholeUnitFixture(parentIdentity: parent, displayIdentity: display)
    let host = try await WholeUnitFixture(parentIdentity: parent, displayIdentity: display)
    defer { try? FileManager.default.removeItem(at: phone.directory); try? FileManager.default.removeItem(at: host.directory) }
    #expect(phone.context.bindingSHA256 == host.context.bindingSHA256)
    let a = try LinkedUnitQuestionSession(store: phone.store, unitOwner: phone.owner)
    let b = try LinkedUnitQuestionSession(store: host.store, unitOwner: host.owner)
    let question = "For the second event, give its current venue address, explain all changes and open current originals."
    let x = try await a.prepare(WholeUnitFixture.input(phone.context, question), context: phone.context,
        activeAnswerRequestID: parent, requestID: request, bindings: phone.bindings)
    let y = try await b.prepare(WholeUnitFixture.input(host.context, question), context: host.context,
        activeAnswerRequestID: parent, requestID: request, bindings: host.bindings)
    #expect(x.task.state == y.task.state)
    #expect(try x.task.digest() == y.task.digest())
    let receipt = try authoredLinkedReceipt(x.task)
    let phoneAnswer = try await a.complete(receipt, for: x, activeRequestID: request)
    let hostAnswer = try await b.complete(receipt, for: y, activeRequestID: request)
    #expect(phoneAnswer.rows.map(\.members) == hostAnswer.rows.map(\.members))
    #expect(phoneAnswer.rows[0].expansions.map(\.reference.id) != hostAnswer.rows[0].expansions.map(\.reference.id))
    do { _ = try await b.complete(receipt, for: x, activeRequestID: request); Issue.record("Replica imported phone prepared authority") } catch {}
    try await phone.store.invalidateSource(id: "photo-update", forget: true)
    do { _ = try await a.admit(phoneAnswer, activeRequestID: request); Issue.record("Forgotten evidence accepted") } catch {}
    _ = try await b.admit(hostAnswer, activeRequestID: request)
    await phone.store.close(); await host.store.close()
}

import Foundation
import IBrain
import IBrainSemantics
import Testing

@Suite struct WorldFacetAuditTests {
    @Test func facetInventoryKeepsOrderDeduplicationAndBothSizeBounds() async throws {
        let scope = MemoryScope(ownerID: "fixture", namespace: "facets")
        let reference = SourceReference(id: "photo", revision: 1, fingerprint: "facets-v1")
        let materials = (0..<32).reversed().map { "material-\($0)" }
        let withinBudget = String(repeating: "é", count: 6_000)
        let inputs = (0..<33).map { (WorldPredicate.category, "category-\($0)", FactOrigin.observed) }
            + materials.map { (.material, $0, .observed) }
            + [(.material, "material-1", .observed), (.material, "inferred material", .inferred),
               (.color, withinBudget, .observed), (.color, withinBudget, .observed),
               (.status, withinBudget, .observed), (.status, "x", .observed)]
        let observations = inputs.enumerated().map { index, row in
            SourceObservation(id: "line-\(index)", value: row.1)
        }
        let source = SourceSnapshot(reference: reference, scope: scope, observations: observations)
        let claims = zip(inputs, observations).map { row, observation in
            WorldClaim(id: observation.id, predicate: row.0, value: .text(row.1), origin: row.2,
                anchors: [.init(source: reference, observationID: observation.id, quote: row.1)], extractorVersion: "authored")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try MemoryStore(directory: directory, scope: scope)
        defer { try? FileManager.default.removeItem(at: directory) }
        let permit = try await store.synchronize(.init(sources: [source], records: [
            .init(id: "item", revision: 1, sources: [reference], recordKind: .worldEntity)
        ]))
        _ = try await store.applyWorldBatch([.init(.init(recordID: "item", recordRevision: 1, scope: scope,
            kind: .object, claims: claims))], permit: permit)
        let prepared = try await WorldQuestionPlanning.prepare(question: "What materials are saved?", taskID: "facet-order",
            requestID: UUID(), store: store, permit: store.permit())
        #expect(prepared.task.unavailableFacetPredicates == [.category, .status])
        #expect(prepared.task.facets.map(\.predicate) == [.color] + Array(repeating: .material, count: 32))
        #expect(prepared.task.facets.map(\.value) == [withinBudget] + materials.sorted())
        #expect(prepared.task.facets.map(\.index) == Array(0..<33))
        await store.close()
    }
}

import IBrain

public struct BoundObservationProposal: Sendable {
    public let candidate: AppointmentCandidate
    public let permit: SnapshotPermit
}
public struct BoundQueryProposal: Sendable {
    public let interpretation: InterpretedQuery
    public let permit: SnapshotPermit
}
public struct BoundGroupingProposal: Sendable {
    public let grouping: ObservationGrouping
    public let permit: SnapshotPermit
}
/// A small bridge around replaceable interpreters. Inference occurs outside
/// the MemoryStore actor; any intervening source/record mutation refuses its
/// proposal. Pin still owns the final domain write/publication transaction.
public enum SemanticSession {
    public static func group(_ request: ObservationRequest, grouper: BoundedSourceGrouper, store: MemoryStore) async throws -> BoundGroupingProposal {
        let permit = try await store.permit()
        let grouping = try await grouper.group(request)
        try await store.validate(permit)
        guard grouping.source == request.source.reference else { throw SemanticError.invalidReceipt }
        return BoundGroupingProposal(grouping: grouping, permit: permit)
    }
    public static func observe(_ request: ObservationRequest, interpreter: any ObservationInterpreter, store: MemoryStore) async throws -> BoundObservationProposal {
        let permit = try await store.permit()
        let candidate = try await interpreter.interpret(request)
        try await store.validate(permit)
        guard candidate.source == request.source.reference else { throw SemanticError.invalidReceipt }
        return BoundObservationProposal(candidate: candidate, permit: permit)
    }
    public static func query(_ request: SemanticQueryRequest, interpreter: any AppointmentQueryInterpreter, store: MemoryStore) async throws -> BoundQueryProposal {
        let permit = try await store.permit()
        let interpretation = try await interpreter.interpret(request)
        try await store.validate(permit)
        return BoundQueryProposal(interpretation: interpretation, permit: permit)
    }
}

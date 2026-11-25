import Foundation
import IBrain

/// One opt-in native capacity contract for field and temporal completion.
/// Retain every scoped observation or refuse. These are not provider limits.
public enum SourceCompletionCapacity: String, Codable, Sendable {
    case bounded64V1, denseSourceV1
    public var fieldPolicy: ObservedTextFieldsPolicy { self == .denseSourceV1 ? .denseSourceV2 : .bounded64V1 }
    public func taskVersion(_ legacy: String) -> String { self == .denseSourceV1 ? legacy + "/dense-source-v1" : legacy }
    internal var stateMarker: String? { self == .denseSourceV1 ? rawValue : nil }
    internal func validateObservations(_ observations: [SourceObservation]) throws {
        guard observations.count <= (self == .denseSourceV1 ? 4096 : 64),
              Set(observations.map(\.id)).count == observations.count else { throw SemanticError.unsupportedEvidence }
        if self == .denseSourceV1 {
            var remaining = 1_048_576
            for observation in observations {
                let size = observation.value.utf8.count
                guard size <= remaining else { throw SemanticError.unsupportedEvidence }
                remaining -= size
            }
        }
    }
    internal func validateState(_ data: Data, legacyMaximum: Int) throws {
        guard data.count <= (self == .denseSourceV1 ? 1_048_576 : legacyMaximum) else { throw SemanticError.unsupportedEvidence }
    }
    internal func checked(_ task: ChoiceTask) throws -> ChoiceTask {
        if self == .denseSourceV1 {
            guard try task.requestData().count <= 1_048_576 else { throw SemanticError.unsupportedEvidence }
        }
        return task
    }
}

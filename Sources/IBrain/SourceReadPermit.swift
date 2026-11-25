import Foundation

/// Opt in only for inference whose entire evidence is one current source.
/// Whole-world queries, bundles, result ordinals and writes keep their grants.
public enum SourceInferenceLiveness: Sendable { case snapshot, independentSource }
public struct SourceReadPermit: Sendable {
    internal let session: UUID
    internal let sourceID: String
    internal let incarnation: UUID
}
public struct SourceReadSnapshot: Sendable {
    public let source: SourceSnapshot
    public let permit: SourceReadPermit
}

import Foundation

/// Native links from exact current source revisions to already-admitted
/// canonical records. A relevance decision never creates these links.
public struct SourceRecordSelection:Sendable {
    public let recordIDs:Set<String>
    public let unlinkedSources:Set<SourceReference>
    public let admittedRecordCount:Int
}

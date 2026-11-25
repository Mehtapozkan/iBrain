import Foundation

public struct RecordInventory:Sendable {
    public let recordIDs:[String]
    /// Includes world/domain pins not represented by an admitted appointment.
    public let unprojectedRecordIDs:Set<String>
    public let unlinkedSources:Set<SourceReference>
    public let pendingSourcePreparations:Set<SourceReference>
    public let sourceReadings:[WorldSourceReading]
    public let permit:SnapshotPermit
}

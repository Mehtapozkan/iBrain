import Foundation

/// Current host-admitted records for bounded interpretation/native operations.
/// This is a derived read, never evidence that the underlying semantic claim
/// is true. Only MemoryStore creates it; keep its original permit through work.
public struct RecordSearchSnapshot: Sendable {
    public let scope: MemoryScope
    public let records: [StoredMemory]
    public let permit: SnapshotPermit
}

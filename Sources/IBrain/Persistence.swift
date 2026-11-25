import Foundation
import Darwin

internal enum PersistenceStage: Sendable { case stagedAndSynced }

/// One writer per directory. A complete staged file is fsynced before atomic
/// rename; reopen ignores an interrupted stage. No fallback to an older backup
/// can resurrect a committed withdrawal. All paths are package storage paths.
internal final class AtomicFile: @unchecked Sendable {
    private let file: URL
    private let pending: URL
    private var lockFD: Int32 = -1
    internal var beforeReplace: (@Sendable (PersistenceStage) throws -> Void)?

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("memory.json")
        pending = directory.appendingPathComponent("memory.pending")
        lockFD = open(directory.appendingPathComponent("writer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { throw MemoryError.persistenceFailure("open writer lock") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD); lockFD = -1; throw MemoryError.storeAlreadyOpen
        }
    }
    deinit { close() }
    func close() {
        if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD); lockFD = -1 }
    }
    func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }
    func write(_ data: Data) throws {
        guard lockFD >= 0 else { throw MemoryError.closed }
        #if os(iOS)
        try data.write(to: pending, options: [.completeFileProtection])
        #else
        try data.write(to: pending)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
        #endif
        let handle = try FileHandle(forWritingTo: pending)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        try beforeReplace?(.stagedAndSynced)
        guard rename(pending.path, file.path) == 0 else { throw MemoryError.persistenceFailure("atomic rename") }
        let directoryFD = open(file.deletingLastPathComponent().path, O_RDONLY)
        guard directoryFD >= 0 else { throw MemoryError.persistenceFailure("open directory after commit; reopen required") }
        defer { Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw MemoryError.persistenceFailure("directory sync after commit; reopen required") }
    }
}

internal struct DiskState: Codable {
    var schema = 1
    let scope: MemoryScope
    var generation: UInt64 = 0
    var rows: [String: StoredMemory] = [:]
    var worldRows: [String: StoredWorldMemory]? = nil
    var recordKinds: [String: DomainRecordKind]? = nil
    var sourceChanges:[String:SourceRecordChange]? = nil
    var recordRevisions: [String: Int] = [:]
    var memoryRevisions: [String: UInt64] = [:]
    var projectionDigests: [String: String] = [:]
    var withdrawnRecords: Set<String> = []
    var forgottenSources: Set<String> = []
}

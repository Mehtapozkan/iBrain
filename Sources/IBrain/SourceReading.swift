import Foundation
import CryptoKit

/// A reader's report, not independently verified transcription accuracy,
/// authenticity, semantic truth or permission to process a source.
public enum SourceReadCoverage: String, Codable, Sendable { case readable, partial, noReadableDetails }
public struct SourceReadAssessment: Codable, Equatable, Sendable {
    public let source: SourceReference
    public let coverage: SourceReadCoverage
    public let reader: String
    public let receiptSHA256: String
    public let observationsSHA256: String
    public init(source: SourceReference, coverage: SourceReadCoverage, reader: String, receiptSHA256: String, observations: [SourceObservation]) throws {
        self.source = source; self.coverage = coverage; self.reader = reader; self.receiptSHA256 = receiptSHA256
        self.observationsSHA256 = try Self.digest(observations)
        try validate(source: source, observations: observations)
    }
    public func validate(source: SourceReference, observations: [SourceObservation]) throws {
        guard self.source == source, !source.id.isEmpty, source.revision > 0, !source.fingerprint.isEmpty,
              !reader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reader.utf8.count <= 2048,
              receiptSHA256.count == 64, receiptSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              observationsSHA256 == (try Self.digest(observations)),
              coverage != .noReadableDetails || observations.allSatisfy({ $0.kind == .visualLabel && $0.value == "reader-reports-multiple-documents" }) else { throw MemoryError.invalidEvidence }
    }
    private static func digest(_ observations: [SourceObservation]) throws -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try e.encode(observations)).map { String(format: "%02x", $0) }.joined()
    }
}
public enum SourceReadingWarning: String, Sendable { case unknown, readerReportedPartial, readerReportedNoReadableDetails }
public struct WorldSourceReading: Codable, Equatable, Sendable {
    public let source: SourceReference
    /// Nil is explicitly unknown, never silently readable.
    public let assessment: SourceReadAssessment?
    public var warning: SourceReadingWarning? {
        switch assessment?.coverage {
        case nil: .unknown
        case .partial: .readerReportedPartial
        case .noReadableDetails: .readerReportedNoReadableDetails
        case .readable: nil
        }
    }
}

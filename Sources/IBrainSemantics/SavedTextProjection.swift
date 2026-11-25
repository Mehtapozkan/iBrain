import Foundation
import IBrain

/// A lossless derived transcription of ONE host-owned saved document, not a
/// claim that it contains one idea or that the person agrees with its content.
/// Host authority/pins and MemoryStore admission remain required separately.
public enum SavedTextProjection {
    public static let version = "saved-text-projection-v1"

    public static func project(_ source: SourceSnapshot, recordID: String,
                               recordRevision: Int, titleObservationID: String? = nil) throws -> WorldMemoryProjection {
        guard !recordID.isEmpty, recordRevision > 0 else { throw SemanticError.unsupportedEvidence }
        var claims: [WorldClaim] = []
        for (index, observation) in source.observations.enumerated() where observation.kind == .text {
            guard !observation.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // Split dense observations without losing text or splitting a Swift
            // Character. Every resulting value is still an exact source span.
            var chunks: [String] = [], chunk = "", chunkBytes = 0
            for character in observation.value {
                let piece = String(character)
                let bytes = piece.utf8.count
                guard bytes <= 12_000 else { throw SemanticError.unsupportedEvidence }
                if chunkBytes + bytes > 12_000 { chunks.append(chunk); chunk = ""; chunkBytes = 0 }
                chunk += piece; chunkBytes += bytes
            }
            if !chunk.isEmpty { chunks.append(chunk) }
            for (part, text) in chunks.enumerated() {
                claims.append(.init(id: "text-\(index)-\(part)", predicate: .observedText, value: .text(text),
                    anchors: [.init(source: source.reference, observationID: observation.id, quote: text)],
                    extractorVersion: version))
            }
        }
        if let titleObservationID {
            guard let title = source.observations.first(where: { $0.id == titleObservationID && $0.kind == .text }),
                  !title.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  title.value.utf8.count <= 16_384 else { throw SemanticError.invalidReceipt }
            claims.append(.init(id: "printed-title", predicate: .name, value: .text(title.value),
                anchors: [.init(source: source.reference, observationID: title.id, quote: title.value)], extractorVersion: version))
        }
        guard !claims.isEmpty, claims.count <= 256 else { throw SemanticError.unsupportedEvidence }
        return .init(recordID: recordID, recordRevision: recordRevision, scope: source.scope, kind: .document, claims: claims)
    }
}

import Foundation
import CryptoKit
import ImageIO
import IBrain
import IBrainSemantics

/// Immutable original bytes, separately authorized by the native source owner.
/// File paths, filenames, capture/archival metadata and gold are not model input.
public enum VisualReadingPolicy:String,Sendable {case literalV1,verbatimFieldsV2,printedStartV3,questionFocusedV4,localOCRDenseV1}
/// Requested reading extent, not a certificate that the reader captured everything.
public enum VisualEvidenceReadScope:String,Sendable {
    case fullDocumentRequested, printedTemporalComponents
}
extension VisualReadingPolicy {
    /// Local whole-text capacity follows the native text-replacement store.
    /// This is not a cloud/model capability or semantic completeness promise.
    public var maximumObservations:Int {self == .localOCRDenseV1 ? 4096:64}
    public var maximumTextBytes:Int {self == .localOCRDenseV1 ? 1_048_576:16_384}
    public var maximumObservationBytes:Int {self == .localOCRDenseV1 ? 1_048_576:512}
    public var contractVersion:String {
        switch self {
        case .literalV1:return "visual-source-evidence-v1"
        case .verbatimFieldsV2:return "visual-source-evidence-v2"
        case .printedStartV3:return "visual-source-evidence-v3"
        case .questionFocusedV4:return "visual-source-evidence-v4"
        case .localOCRDenseV1:return "local-ocr-dense-source-evidence-v1"
        }
    }
    public var readScope:VisualEvidenceReadScope {
        self == .printedStartV3 ? .printedTemporalComponents:.fullDocumentRequested
    }
}
public struct VisualEvidenceRequest: Sendable {
    public let readingPolicy:VisualReadingPolicy
    public let requestedQuestionFields:Set<RequestedAppointmentDetail>
    public let requestedPrintedParts:Set<PrintedFactRequirement>
    public static let contractVersion = "visual-source-evidence-v1"
    public static let frameVersion = "imageio-oriented-full-frame-2048-jpeg95-v1"
    public static let frameVersionV2="imageio-oriented-full-frame-2048-pixels2400000-jpeg95-v2"
    public let taskID: String
    public let source: SourceSnapshot
    public let imageData: Data
    public let sourceImageBinding:SourceImageBinding?
    private let preparedFrame: PreparedVisualFrame?
    public init(taskID: String, source: SourceSnapshot, imageData: Data, readingPolicy:VisualReadingPolicy = .literalV1,requestedPrintedParts:Set<PrintedFactRequirement> = [.localDate,.startClock,.explicitTimeZone],requestedQuestionFields:Set<RequestedAppointmentDetail> = []) {
        self.readingPolicy=readingPolicy;self.requestedPrintedParts=requestedPrintedParts;self.requestedQuestionFields=requestedQuestionFields
        self.taskID = taskID; self.source = source; self.imageData = imageData
        self.sourceImageBinding=nil
        // Preserve the nonthrowing initializer; invalid input still fails validate.
        // A request prepares at most once. Its data/digest never re-encode later.
        self.preparedFrame = !taskID.isEmpty && Self.hash(imageData) == source.reference.fingerprint
            ? try? PreparedVisualFrame.prepare(originalImageData: imageData) : nil
    }
    public init(taskID: String, source: SourceSnapshot, imageData: Data, preparedFrame: PreparedVisualFrame, readingPolicy:VisualReadingPolicy = .literalV1,requestedPrintedParts:Set<PrintedFactRequirement> = [.localDate,.startClock,.explicitTimeZone],requestedQuestionFields:Set<RequestedAppointmentDetail> = []) throws {
        self.readingPolicy=readingPolicy;self.requestedPrintedParts=requestedPrintedParts;self.requestedQuestionFields=requestedQuestionFields
        self.taskID = taskID; self.source = source; self.imageData = imageData
        self.sourceImageBinding=nil
        self.preparedFrame = preparedFrame
        try validate()
    }
    /// Explicit host-attested acquisition mode. The native metadata fingerprint
    /// remains untouched; immutable input bytes have a separate bound SHA.
    public init(taskID:String,binding:SourceImageBinding,imageData:Data,preparedFrame:PreparedVisualFrame?=nil,readingPolicy:VisualReadingPolicy = .literalV1,requestedPrintedParts:Set<PrintedFactRequirement> = [.localDate,.startClock,.explicitTimeZone],requestedQuestionFields:Set<RequestedAppointmentDetail> = [])throws {
        guard !imageData.isEmpty,imageData.count<=10_000_000,Self.hash(imageData)==binding.imageSHA256 else{throw SemanticError.unsupportedEvidence}
        self.taskID=taskID;self.source=binding.source;self.imageData=imageData;self.sourceImageBinding=binding
        self.readingPolicy=readingPolicy;self.requestedPrintedParts=requestedPrintedParts;self.requestedQuestionFields=requestedQuestionFields
        self.preparedFrame=try preparedFrame ?? PreparedVisualFrame.prepare(originalImageData:imageData)
        try validate()
    }
    public var logicalContractVersion:String {
        let base=readingPolicy.contractVersion
        return sourceImageBinding==nil ? base:base+"-host-image-binding-v1"
    }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public func validate() throws {
        guard readingPolicy != .questionFocusedV4 || !requestedQuestionFields.isEmpty else{throw SemanticError.unsupportedEvidence}
        guard readingPolicy != .printedStartV3 || !requestedPrintedParts.isEmpty else{throw SemanticError.unsupportedEvidence}
        let expected=sourceImageBinding?.imageSHA256 ?? source.reference.fingerprint
        guard sourceImageBinding.map({$0.source==source}) ?? true,
              !taskID.isEmpty, !imageData.isEmpty, imageData.count <= 10_000_000,
              Self.hash(imageData) == expected,
              let preparedFrame, preparedFrame.originalSHA256 == expected,
              [Self.frameVersion,Self.frameVersionV2].contains(preparedFrame.preprocessing) else { throw SemanticError.unsupportedEvidence }
    }
    /// Full frame, orientation applied, metadata stripped. No crop or text
    /// selection. The exact derived bytes are separately hash-bound below.
    public func modelImageData() throws -> Data {
        try validate()
        return preparedFrame!.imageData
    }
    /// Persist before dispatch; restore these bytes instead of deriving a new frame.
    public func preparedFrameArtifact() throws -> Data {
        try validate()
        return try preparedFrame!.encodedArtifact()
    }
    public func requestData() throws -> Data {
        try validate()
        struct Input: Encodable {
            let contract: String; let taskID: String; let source: SourceReference
            let coordinateSpace: String; let maximumObservations: Int
            let maximumTextBytes:Int?;let maximumObservationBytes:Int?;let allowedObservationKinds:[String]?
            let modelFrameSHA256: String; let preprocessing: String
            let readingPolicy:String?
            let requestedFields:[String]?
            let sourceImageBinding:SourceImageBindingProvenance?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Input(contract:logicalContractVersion, taskID: taskID, source: source.reference,
            coordinateSpace: "oriented image; integer thousandths; left,top,right,bottom", maximumObservations: readingPolicy.maximumObservations,
            maximumTextBytes:readingPolicy == .localOCRDenseV1 ? readingPolicy.maximumTextBytes:nil,maximumObservationBytes:readingPolicy == .localOCRDenseV1 ? readingPolicy.maximumObservationBytes:nil,allowedObservationKinds:readingPolicy == .localOCRDenseV1 ? ["text"]:nil,
            modelFrameSHA256: Self.hash(try modelImageData()), preprocessing:preparedFrame!.preprocessing,readingPolicy:readingPolicy == .literalV1 ? nil:readingPolicy.rawValue,requestedFields:readingPolicy == .printedStartV3 ? requestedPrintedParts.map(\.rawValue).sorted():readingPolicy == .questionFocusedV4 ? requestedQuestionFields.map(\.rawValue).sorted():nil,sourceImageBinding:sourceImageBinding?.provenance))
    }
}

public typealias VisualReadCoverage = SourceReadCoverage
public struct VisualReadObservation: Codable, Sendable {
    public let kind: ObservationKind
    public let value: String
    public let box: [Int]
    public init(kind: ObservationKind, value: String, box: [Int]) { self.kind = kind; self.value = value; self.box = box }
}
public struct VisualEvidenceReceipt: Codable, Sendable {
    public let provider: String
    public let model: String
    public let requestSHA256: String
    public let coverage: VisualReadCoverage
    /// Reported by the reader, not independently verified object counts.
    public let visibleDocumentCount: Int
    public let observations: [VisualReadObservation]
    public let elapsedSeconds: Double
    public init(provider: String, model: String, requestSHA256: String, coverage: VisualReadCoverage,
                visibleDocumentCount: Int, observations: [VisualReadObservation], elapsedSeconds: Double) {
        self.provider = provider; self.model = model; self.requestSHA256 = requestSHA256
        self.coverage = coverage; self.visibleDocumentCount = visibleDocumentCount
        self.observations = observations; self.elapsedSeconds = elapsedSeconds
    }
    public func validate(for request: VisualEvidenceRequest) throws {
        try request.validate()
        guard !provider.isEmpty, !model.isEmpty, requestSHA256 == (try VisualEvidenceRequest.hash(request.requestData())),
              elapsedSeconds.isFinite, elapsedSeconds >= 0, (0...8).contains(visibleDocumentCount),
              observations.count <= request.readingPolicy.maximumObservations, observations.reduce(0, { $0 + $1.value.utf8.count }) <= request.readingPolicy.maximumTextBytes,
              request.readingPolicy != .localOCRDenseV1 || (visibleDocumentCount==0 && observations.allSatisfy{$0.kind == .text}),
              observations.filter({ $0.kind == .visualLabel }).count <= 8,
              coverage != .noReadableDetails || observations.isEmpty else { throw SemanticError.invalidReceipt }
        let labels: Set<String> = ["printed-ticket-body", "machine-readable-barcode", "perforated-ticket-edge",
            "poster-or-purchase-invitation", "physical-machine-or-counter", "overlapping-documents", "other-visible-document-feature"]
        for item in observations {
            guard !item.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.value.utf8.count <= request.readingPolicy.maximumObservationBytes, !item.value.contains("\0"),
                  item.box.count == 4, item.box.allSatisfy({ (0...1000).contains($0) }),
                  item.box[0] < item.box[2], item.box[1] < item.box[3],
                  item.kind == .text || labels.contains(item.value) else { throw SemanticError.invalidReceipt }
        }
    }
}
public protocol VisualEvidenceReader: Sendable {
    func read(_ request: VisualEvidenceRequest) async throws -> VisualEvidenceReceipt
}
public struct PreparedVisualEvidence: Sendable {
    internal let sourceImageBinding:SourceImageBinding?
    public var imageBindingProvenance:SourceImageBindingProvenance? {sourceImageBinding?.provenance}
    public let requestedPrintedParts:Set<PrintedFactRequirement>
    public let taskID: String
    public let originalSource: SourceSnapshot
    public let readingPolicy:VisualReadingPolicy
    public let receipt: VisualEvidenceReceipt
    internal let permit: SnapshotPermit
    internal let sourcePermit: SourceReadPermit?
}
public struct AdmittedVisualEvidence: Sendable {
    public let readingPolicy:VisualReadingPolicy
    public var readScope:VisualEvidenceReadScope {readingPolicy.readScope}
    public let imageBindingProvenance:SourceImageBindingProvenance?
    public let originalSource: SourceReference
    public let originalScope: MemoryScope
    public let originalCapturedAt: Date?
    public let originalCaptureTimestampOrigin:CaptureTimestampOrigin?
    public let originalImportedAt:Date?
    public let originalRelativeDayAnchorContemporaneous:Bool?
    public let observations: [SourceObservation]
    public let textLines: [ObservedLine]
    public let observationRegions: [String: ObservationRegion]
    public let coverage: VisualReadCoverage
    public let visibleDocumentCount: Int
    public let receiptSHA256: String
    public let extractorVersion: String
    /// The source owner still admits/persists this revised source in its own
    /// existing index. This helper supplies no independent write authority.
    public func revisedSourceSnapshot(revision: Int) throws -> SourceSnapshot {
        guard readScope == .fullDocumentRequested else {throw SemanticError.unsupportedEvidence}
        return try readingCandidateSnapshot(revision:revision)
    }
    /// A temporary evidence view for field interpretation/reconciliation. It is
    /// NOT a whole-source replacement. Scoped readings must pass the native
    /// merge/CAS path, preserving all untouched observations and their lineage.
    public func readingCandidateSnapshot(revision:Int)throws -> SourceSnapshot {
        guard revision > originalSource.revision else { throw SemanticError.unsupportedEvidence }
        let revised = SourceReference(id: originalSource.id, revision: revision, fingerprint: originalSource.fingerprint)
        let assessment = try SourceReadAssessment(source: revised, coverage: coverage, reader: extractorVersion,
            receiptSHA256: receiptSHA256, observations: observations)
        return SourceSnapshot(reference: revised,
            scope: originalScope, observations: observations, capturedAt: originalCapturedAt, readAssessment: assessment,captureTimestampOrigin:originalCaptureTimestampOrigin,importedAt:originalImportedAt,relativeDayAnchorContemporaneous:originalRelativeDayAnchorContemporaneous)
    }
}

/// Validates bindings and current native access, not truth of image claims.
/// Admission returns observations only; the host still owns source revisions,
/// semantic/domain validation and the complete authority transaction.
public enum VisualEvidenceSession {
    public static func prepare(_ request: VisualEvidenceRequest, reader: any VisualEvidenceReader,
                               store: MemoryStore, liveness: SourceInferenceLiveness = .snapshot) async throws -> PreparedVisualEvidence {
        try request.validate()
        if let binding=request.sourceImageBinding{try Task.checkCancellation();try await store.validate(binding)}
        let permit = try await store.permit()
        let sourcePermit: SourceReadPermit?
        if liveness == .independentSource {
            let current = try await store.sourceReadSnapshot(sourceID: request.source.reference.id, permit: permit)
            guard current.source == request.source else { throw SemanticError.unsupportedEvidence }
            sourcePermit = current.permit
        } else {
            let current = try await store.sourceSearchSnapshot(permit: permit)
            guard current.sources.contains(request.source) else { throw SemanticError.unsupportedEvidence }
            sourcePermit = nil
        }
        let receipt = try await reader.read(request)
        try await validate(permit, sourcePermit, store: store); try receipt.validate(for: request)
        if let binding=request.sourceImageBinding{try Task.checkCancellation();try await store.validate(binding)}
        return PreparedVisualEvidence(sourceImageBinding:request.sourceImageBinding,requestedPrintedParts:request.requestedPrintedParts,taskID: request.taskID, originalSource: request.source, readingPolicy:request.readingPolicy, receipt: receipt, permit: permit, sourcePermit: sourcePermit)
    }
    public static func admit(_ prepared: PreparedVisualEvidence, activeTaskID: String,
                             store: MemoryStore) async throws -> AdmittedVisualEvidence {
        guard prepared.taskID == activeTaskID else { throw SemanticError.invalidReceipt }
        try await validate(prepared.permit, prepared.sourcePermit, store: store)
        if let binding=prepared.sourceImageBinding{try Task.checkCancellation();try await store.validate(binding)}
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = VisualEvidenceRequest.hash(try encoder.encode(prepared.receipt))
        var observations: [SourceObservation] = [], lines: [ObservedLine] = [], regions: [String: ObservationRegion] = [:]
        for (index, item) in prepared.receipt.observations.enumerated() {
            let id = "vr-" + digest.prefix(16) + String(format: "-%03d", index)
            observations.append(SourceObservation(id: id, kind: item.kind, value: item.value))
            let b = item.box
            let region = ObservationRegion(x: Double(b[0]) / 1000, y: Double(1000 - b[3]) / 1000,
                width: Double(b[2] - b[0]) / 1000, height: Double(b[3] - b[1]) / 1000)
            guard region.isValid else { throw SemanticError.invalidReceipt }
            regions[id] = region
            if item.kind == .text {
                // The reader supplies no calibrated confidence. Zero is an
                // explicitly unavailable numeric placeholder, not a probability.
                lines.append(ObservedLine(id: id, text: item.value, confidence: 0, region: region))
            }
        }
        if prepared.receipt.visibleDocumentCount > 1 {
            observations.append(SourceObservation(id: "vr-" + digest.prefix(16) + "-count", kind: .visualLabel,
                value: "reader-reports-multiple-documents"))
        }
        try await validate(prepared.permit, prepared.sourcePermit, store: store)
        if let binding=prepared.sourceImageBinding{try Task.checkCancellation();try await store.validate(binding)}
        let bindingSuffix=prepared.sourceImageBinding==nil ? "":"-host-image-binding-v1"
        return AdmittedVisualEvidence(readingPolicy:prepared.readingPolicy,imageBindingProvenance:prepared.imageBindingProvenance,originalSource: prepared.originalSource.reference, originalScope: prepared.originalSource.scope,
            originalCapturedAt: prepared.originalSource.capturedAt,originalCaptureTimestampOrigin:prepared.originalSource.captureTimestampOrigin,originalImportedAt:prepared.originalSource.importedAt,originalRelativeDayAnchorContemporaneous:prepared.originalSource.relativeDayAnchorContemporaneous, observations: observations, textLines: lines, observationRegions: regions,
            coverage: prepared.receipt.coverage, visibleDocumentCount: prepared.receipt.visibleDocumentCount,
            receiptSHA256: digest, extractorVersion: "\(prepared.receipt.provider)/\(prepared.receipt.model)/\(prepared.readingPolicy.contractVersion)\(bindingSuffix)/\(digest)/confidence-unavailable")
    }
    private static func validate(_ snapshot: SnapshotPermit, _ source: SourceReadPermit?, store: MemoryStore) async throws {
        if let source { try await store.validate(source) } else { try await store.validate(snapshot) }
    }
}

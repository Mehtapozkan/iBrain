import Foundation
import ImageIO
import IBrainSemantics

/// Immutable output of native image preparation. The host can freeze these exact
/// bytes before dispatch and restore them without re-encoding an original.
public enum VisualFramePolicy:Sendable {case legacy2048JPEG95,pixelBound2400kV2}
public struct PreparedVisualFrame: Sendable, Equatable {
    public static let artifactVersion = "visual-prepared-frame-v1"
    public let originalSHA256: String
    public let preprocessing: String
    public let imageSHA256: String
    public let imageData: Data

    private struct Artifact: Codable {
        let version: String
        let originalSHA256: String
        let preprocessing: String
        let imageSHA256: String
        let imageData: Data
    }

    internal static func originalInfo(_ data: Data) throws -> (width: Int, height: Int, orientation: Int) {
        guard !data.isEmpty, data.count <= 10_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (info[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (info[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 12_000, height <= 12_000,
              width * height <= 40_000_000 else { throw SemanticError.unsupportedEvidence }
        let orientation = (info[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else { throw SemanticError.unsupportedEvidence }
        return (width, height, orientation)
    }

    private init(originalImageData:Data,imageData:Data,expectedImageSHA256:String,preprocessing:String=VisualEvidenceRequest.frameVersion)throws {
        let original = try Self.originalInfo(originalImageData)
        guard !imageData.isEmpty, imageData.count <= 10_000_000,
              VisualEvidenceRequest.hash(imageData) == expectedImageSHA256,
              let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (info[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (info[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 2048, height <= 2048,
              info[kCGImagePropertyGPSDictionary] == nil,
              ((info[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) == 1 else {
            throw SemanticError.unsupportedEvidence
        }
        // ImageIO writes dimensional EXIF even when source metadata is stripped.
        // Retain that structural metadata, never a capture timestamp or GPS.
        let exif = info[kCGImagePropertyExifDictionary] as? [String: Any] ?? [:]
        guard Set(exif.keys).isSubset(of: ["PixelXDimension", "PixelYDimension", "ColorSpace"]),
              info[kCGImagePropertyTIFFDictionary] == nil,
              info[kCGImagePropertyIPTCDictionary] == nil else { throw SemanticError.unsupportedEvidence }
        let swapped = (5...8).contains(original.orientation)
        let ow = swapped ? original.height : original.width
        let oh = swapped ? original.width : original.height
        guard [VisualEvidenceRequest.frameVersion,VisualEvidenceRequest.frameVersionV2].contains(preprocessing)else{throw SemanticError.unsupportedEvidence}
        let pixelBound=preprocessing==VisualEvidenceRequest.frameVersionV2
        let limit=pixelBound ? min(2048,max(1,Int(floor(Double(max(ow,oh))*min(1.0,sqrt(2_400_000.0/Double(ow*oh)))))-(ow*oh>2_400_000 ? 1:0))):2048
        let scale=min(1.0,Double(limit)/Double(max(ow,oh)))
        if pixelBound {guard width*height<=2_400_000 else{throw SemanticError.unsupportedEvidence}}
        // ImageIO may round the short edge; reject changed aspect or dimensions.
        guard abs(Double(width) - Double(ow) * scale) <= 1,
              abs(Double(height) - Double(oh) * scale) <= 1 else { throw SemanticError.unsupportedEvidence }
        self.originalSHA256 = VisualEvidenceRequest.hash(originalImageData)
        self.preprocessing = preprocessing
        self.imageSHA256 = expectedImageSHA256
        self.imageData = imageData
    }

    public static func prepare(originalImageData:Data,policy:VisualFramePolicy = .legacy2048JPEG95)throws -> PreparedVisualFrame {
        let original=try originalInfo(originalImageData)
        let long=max(original.width,original.height),count=original.width*original.height
        let limit=policy == .pixelBound2400kV2 ? min(2048,max(1,Int(floor(Double(long)*min(1.0,sqrt(2_400_000.0/Double(count)))))-(count>2_400_000 ? 1:0))):2048
        guard let source = CGImageSourceCreateWithData(originalImageData as CFData, nil),
              let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit] as CFDictionary) else { throw SemanticError.unsupportedEvidence }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw SemanticError.unsupportedEvidence
        }
        CGImageDestinationAddImage(output, frame, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw SemanticError.unsupportedEvidence }
        let bytes = data as Data
        return try Self(originalImageData: originalImageData, imageData: bytes, expectedImageSHA256:VisualEvidenceRequest.hash(bytes),preprocessing:policy == .pixelBound2400kV2 ? VisualEvidenceRequest.frameVersionV2:VisualEvidenceRequest.frameVersion)
    }

    public func encodedArtifact() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Artifact(version: Self.artifactVersion, originalSHA256: originalSHA256,
            preprocessing: preprocessing, imageSHA256: imageSHA256, imageData: imageData))
    }

    /// Restore only an artifact prepared and retained by the trusted native host.
    /// Hashes/dimensions validate consistency, not pixel derivation, authenticity,
    /// ownership or safety of an arbitrary externally supplied replacement image.
    public static func restoreTrustedHostArtifact(_ data: Data, originalImageData: Data) throws -> PreparedVisualFrame {
        guard data.count <= 14_000_000 else { throw SemanticError.unsupportedEvidence }
        let artifact: Artifact
        do { artifact = try JSONDecoder().decode(Artifact.self, from: data) }
        catch { throw SemanticError.unsupportedEvidence }
        guard artifact.version == artifactVersion, [VisualEvidenceRequest.frameVersion,VisualEvidenceRequest.frameVersionV2].contains(artifact.preprocessing),
              artifact.originalSHA256 == VisualEvidenceRequest.hash(originalImageData) else { throw SemanticError.unsupportedEvidence }
        return try Self(originalImageData: originalImageData, imageData: artifact.imageData, expectedImageSHA256:artifact.imageSHA256,preprocessing:artifact.preprocessing)
    }
}

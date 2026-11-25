import Foundation

/// Audit data only. Decoding this does not restore a source read grant.
public struct SourceImageBindingProvenance:Codable,Equatable,Sendable {
    public let version:String
    public let source:SourceReference
    public let scope:MemoryScope
    public let imageSHA256:String
    public let acquisitionID:UUID
}

/// Opaque, process-local host attestation. The trusted native source owner
/// acquired immutable bytes for this exact current photo. iBrain checks the
/// association's current grant and byte digest; it cannot inspect PhotoKit.
/// The native owner must validate actual asset, access, request and metadata
/// before/after acquisition. Display renditions do not imply this attestation.
public struct SourceImageBinding:Sendable {
    public static let version="host-source-image-binding-v1"
    public let source:SourceSnapshot
    public let imageSHA256:String
    public let acquisitionID:UUID
    internal let permit:SourceReadPermit
    public var provenance:SourceImageBindingProvenance {
        SourceImageBindingProvenance(version:Self.version,source:source.reference,scope:source.scope,imageSHA256:imageSHA256,acquisitionID:acquisitionID)
    }
}

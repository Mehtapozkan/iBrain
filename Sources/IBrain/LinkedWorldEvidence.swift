import Foundation

/// Compact metadata for an already host-admitted world entity. It is not a
/// permit, an inferred identity match or a durable application record.
public struct LinkedWorldHeader:Codable,Equatable,Sendable {
    public let recordID:String
    public let recordRevision:Int
    public let kind:WorldEntityKind
    public let identifyingTexts:[String]
    public let identifyingClaims:[WorldClaim]
    public let sources:[SourceReference]
}

import Foundation
import IBrain

/// Untrusted document-region proposals from an image-reading generation.
/// Coordinates use the same normalized bottom-left space as observations.
/// Input provenance and the native proposal digest are distinct. Regions/count
/// from one generation do not constitute independent corroboration.
public struct VisualDocumentRegionProposal: Codable, Sendable {
    public static let contractVersion="visual-document-regions-v1"
    public let source:SourceReference
    public let observationIDs:[String]
    public let readingReceiptSHA256:String
    public let modelInputSHA256:String
    public let regions:[ObservationRegion]
    public init(source:SourceReference,observationIDs:[String],readingReceiptSHA256:String,modelInputSHA256:String,regions:[ObservationRegion]) {
        self.source=source;self.observationIDs=observationIDs;self.readingReceiptSHA256=readingReceiptSHA256;self.modelInputSHA256=modelInputSHA256;self.regions=regions
    }
    public func digest()throws->String {let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return ChoiceTask.hash(try e.encode(self))}
}
public struct VisualRegionObservationGrouping: Sendable {
    public let source:SourceReference
    public let scopes:[VisualGroupScope]
    public let contextObservationIDs:[String]
    public let proposal:VisualDocumentRegionProposal
    public let proposalSHA256:String
    internal let originalSource:SourceSnapshot
    internal let lines:[ObservedLine]
    internal func request(ordinal:Int,taskID:String,temporalPolicy:ObservationTemporalPolicy)throws->ObservationRequest {
        guard let scope=scopes.first(where:{$0.ordinal==ordinal})else{throw SemanticError.unsupportedEvidence}
        let ids=Set(scope.observationIDs)
        return ObservationRequest(taskID:taskID,source:originalSource,lines:lines.filter{ids.contains($0.id)},declaredVisualClues:originalSource.observations.filter{ids.contains($0.id) && $0.kind == .visualLabel}.map(\.value),temporalPolicy:temporalPolicy,visualGroupScope:scope)
    }
}
public struct BoundVisualRegionGrouping: Sendable {
    public let grouping:VisualRegionObservationGrouping
    public let permit:SnapshotPermit
}
/// Optional native scoping, not a Choice model decision or domain admission.
/// Validates bindings/geometry/currentness, not truth of the image claims.
public enum VisualRegionGroupingSession {
    private static func validDigest(_ s:String)->Bool {s.count==64 && s.allSatisfy{"0123456789abcdef".contains($0)}}
    private static func intersects(_ a:ObservationRegion,_ b:ObservationRegion)->Bool {
        min(a.x+a.width,b.x+b.width)-max(a.x,b.x)>1e-9 && min(a.y+a.height,b.y+b.height)-max(a.y,b.y)>1e-9
    }
    private static func contains(_ outer:ObservationRegion,_ inner:ObservationRegion)->Bool {
        inner.x>=outer.x-1e-9 && inner.y>=outer.y-1e-9 && inner.x+inner.width<=outer.x+outer.width+1e-9 && inner.y+inner.height<=outer.y+outer.height+1e-9
    }
    public static func group(_ request:VisualGroupingRequest,proposal:VisualDocumentRegionProposal,store:MemoryStore) async throws->BoundVisualRegionGrouping {
        let permit=try await store.permit()
        guard try await store.sourceSearchSnapshot(permit:permit).sources.contains(request.source)else{throw SemanticError.unsupportedEvidence}
        try request.validate()
        guard proposal.source==request.source.reference,Set(proposal.observationIDs)==Set(request.assignable.map(\.id)),Set(proposal.observationIDs).count==proposal.observationIDs.count,
              validDigest(proposal.readingReceiptSHA256),validDigest(proposal.modelInputSHA256),proposal.regions.count<=3,
              proposal.regions.count==request.reportedDocumentCount,proposal.regions.allSatisfy(\.isValid)else{throw SemanticError.unsupportedEvidence}
        let regions=proposal.regions
        for i in regions.indices {for j in regions.indices where j>i {
            if intersects(regions[i],regions[j]){throw SemanticError.unresolved("overlapping proposed document regions")}
        }}
        var members=Array(repeating:[String](),count:regions.count),context:[String]=[]
        for observation in request.assignable {
            guard let box=request.observationRegions[observation.id]else{throw SemanticError.unsupportedEvidence}
            let matches=regions.indices.filter{intersects(regions[$0],box)}
            if matches.isEmpty{context.append(observation.id);continue}
            guard matches.count==1,contains(regions[matches[0]],box)else{throw SemanticError.unresolved("observation crosses proposed document boundaries")}
            members[matches[0]].append(observation.id)
        }
        guard members.allSatisfy({!$0.isEmpty})else{throw SemanticError.unresolved("empty proposed document region")}
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys]
        let scopes=try members.enumerated().map{index,ids in
            let set=Set(ids)
            // This is the actual model-input provenance hash, not a fabricated
            // ChoiceTask receipt. Selected IDs/lines also bind the child task.
            return VisualGroupScope(ordinal:index+1,groupCount:members.count,groupingRequestSHA256:proposal.modelInputSHA256,observationIDs:ids,source:request.source,linesData:try e.encode(request.lines.filter{set.contains($0.id)}))
        }
        try await store.validate(permit)
        return BoundVisualRegionGrouping(grouping:VisualRegionObservationGrouping(source:request.source.reference,scopes:scopes,contextObservationIDs:context,proposal:proposal,proposalSHA256:try proposal.digest(),originalSource:request.source,lines:request.lines),permit:permit)
    }
    public static func observe(_ bound:BoundVisualRegionGrouping,ordinal:Int,taskID:String,temporalPolicy:ObservationTemporalPolicy = .anchoredSpansV3,interpreter:any ObservationInterpreter,store:MemoryStore) async throws->BoundObservationProposal {
        try await store.validate(bound.permit)
        guard try await store.sourceSearchSnapshot(permit:bound.permit).sources.contains(bound.grouping.originalSource)else{throw SemanticError.unsupportedEvidence}
        let request=try bound.grouping.request(ordinal:ordinal,taskID:taskID,temporalPolicy:temporalPolicy),candidate=try await interpreter.interpret(request)
        try await store.validate(bound.permit)
        guard candidate.source==bound.grouping.source else{throw SemanticError.invalidReceipt}
        return BoundObservationProposal(candidate:candidate,permit:bound.permit)
    }
}

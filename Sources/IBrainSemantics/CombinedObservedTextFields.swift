import Foundation
import IBrain

/// Explicit opt-in composition of existing field decisions. One actual receipt
/// belongs to the combined contract; no synthetic per-field receipts are made.
public enum CombinedObservedTextFieldsInterpreter {
    public static let version="observed-text-fields-combined-v1"
    public static let denseVersion=version+"/dense-source-v1"
    private static func bytes<T:Encodable>(_ value:T)throws->Data {
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(value)
    }
    public static func task(id:String,context:ObservedTextFieldsContext,fields:Set<EvidenceTextField>,policy:ObservedTextFieldsPolicy = .bounded64V1)throws->ChoiceTask {
        guard !id.isEmpty,!fields.isEmpty else{throw SemanticError.unsupportedEvidence}
        struct Row:Encodable {let id:String;let text:String}
        struct Field:Encodable {let alias:String;let field:EvidenceTextField;let currentValue:String?;let standaloneTaskSHA256:String}
        struct State:Encodable {let contract:String;let source:SourceReference;let sourceSnapshotSHA256:String;let baseProjectionSHA256:String;let fields:[Field];let lines:[Row];let evidencePolicy:String}
        var bound:[Field]=[],questions:[String:ChoiceQuestion]=[:]
        for (i,field) in fields.sorted(by:{$0.rawValue<$1.rawValue}).enumerated() {
            let original=try ObservedTextFieldsInterpreter.task(id:id+"-"+field.rawValue,context:context,field:field,policy:policy)
            struct OriginalState:Decodable {let currentValue:String?}
            let originalState=try JSONDecoder().decode(OriginalState.self,from:Data(original.state.utf8)),alias="f\(i)"
            bound.append(Field(alias:alias,field:field,currentValue:originalState.currentValue,standaloneTaskSHA256:ChoiceTask.hash(try bytes(original))))
            for (key,q) in original.questions {
                questions[alias+"_"+key]=ChoiceQuestion("This question belongs ONLY to field "+alias+" ("+field.rawValue+"). Read its currentValue in state.fields and the shared lines. For this field, mode means "+alias+"_mode and part_N means "+alias+"_part_N. Other fields have independent decisions against the same immutable base. "+q.instructions,q.criteria)
            }
        }
        let contract=policy == .denseSourceV2 ? denseVersion:version
        let state=State(contract:contract,source:context.source.reference,sourceSnapshotSHA256:ChoiceTask.hash(try bytes(context.source)),baseProjectionSHA256:ChoiceTask.hash(try bytes(context.current)),fields:bound,lines:context.source.observations.filter{$0.kind == .text}.enumerated().map{Row(id:"line-\($0.offset+1)",text:$0.element.value)},evidencePolicy:policy.rawValue)
        let task=ChoiceTask(id:id,state:String(decoding:try bytes(state),as:UTF8.self),questions:questions,version:contract)
        // This new contract is bounded even under its small-source policy.
        guard try task.requestData().count<=1_048_576 else{throw SemanticError.unsupportedEvidence}
        return task
    }
    public static func compile(_ receipt:DecisionReceipt,task:ChoiceTask,id:String,context:ObservedTextFieldsContext,fields:Set<EvidenceTextField>,policy:ObservedTextFieldsPolicy = .bounded64V1)throws->ObservedTextFieldsCompletion {
        let expected=try Self.task(id:id,context:context,fields:fields,policy:policy)
        guard try bytes(task)==bytes(expected) else{throw SemanticError.invalidReceipt}
        try receipt.validate(for:task)
        var result=context.current,unresolved=Set<EvidenceTextField>()
        for (i,field) in fields.sorted(by:{$0.rawValue<$1.rawValue}).enumerated() {
            let view=CombinedFieldChoices(raw:receipt,prefix:"f\(i)_")
            let applied=try ObservedTextFieldsInterpreter.apply(view,to:result,context:context,field:field,policy:policy,extractorVersion:receipt.provider+"/"+receipt.model+"/"+task.version+"/"+receipt.requestSHA256)
            result=applied.projection;if applied.unresolved{unresolved.insert(field)}
        }
        return ObservedTextFieldsCompletion(projection:result,unresolvedFields:unresolved,receipts:[receipt])
    }
}
private struct CombinedFieldChoices:DecisionChoiceReading {
    let raw:DecisionReceipt
    let prefix:String
    func choice(_ id:String)throws->String {try raw.choice(prefix+id)}
}

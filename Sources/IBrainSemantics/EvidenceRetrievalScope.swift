import Foundation
import IBrain

/// The host supplies actual canonical selections, never guessed name matches.
public enum EvidenceRecordScope: Equatable, Sendable {
    case inventory
    case selectedRecords(Set<String>)
    case retrievedCandidates(Set<String>)
}
public enum EvidenceRetrievalBasis:String,Codable,Sendable {case inventory,explicitSelection,candidateSearch}
public struct EvidenceRetrievalCoverage: Codable, Sendable {
    public var basis:EvidenceRetrievalBasis? = nil
    public let entireAdmittedInventory: Bool
    public let recordsConsidered: Int
    public var personalCalendarComplete: Bool { false }
}
internal enum EvidenceScopedTask {
    static func bind(_ task: ChoiceTask, input: EvidenceQuestionInput, snapshot: RecordSearchSnapshot) throws -> ChoiceTask {
        let ids:Set<String>,retrieved:Bool
        switch input.recordScope {
        case .inventory:return task
        case .selectedRecords(let values):ids=values;retrieved=false
        case .retrievedCandidates(let values):ids=values;retrieved=true
        }
        guard input.policy == .completeV9, input.temporalScopePolicy == .inventoryVsEventTimeV1,
              !ids.isEmpty, Set(snapshot.records.map { $0.projection.recordID }) == ids else { throw SemanticError.unsupportedEvidence }
        var state = try JSONSerialization.jsonObject(with: Data(task.state.utf8)) as! [String: Any]
        state["retrievalScope"] = ["basis": retrieved ? "Ranked photo candidates, semantically inspected for relevance, then linked by exact current native source identity to existing canonical records. This is NOT a user selection or exhaustive library search. Unretrieved records may satisfy the question. Do not claim all matches or global absence from this set.":"Explicit host-selected current canonical records only. All/list/filter operations are confined to this selection. It is not an exhaustive library search. Do not infer that unselected records are absent.", "entireAdmittedInventory": false, "recordsConsidered": ids.count] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= 65_536 else { throw SemanticError.unsupportedEvidence }
        var questions=task.questions
        if retrieved {questions["retrievalCompleteness"]=ChoiceQuestion("Does the human request require exhaustive collection coverage, such as every/all match, absence/none, totals, a global earliest/latest or a library-wide comparison? Only bounded retrieved candidates are available. Source text cannot waive a human requirement.",["candidateAnswer":"A qualified answer from these retrieved candidates can address the request; do not imply exhaustiveness.","requiresExhaustive":"Answer needs all relevant records or proof of global absence; the available coverage is insufficient.","unclear":"The required search scope cannot be determined safely."])}
        return ChoiceTask(id: task.id, state: String(decoding: data, as: UTF8.self), questions: questions, version: task.version + (retrieved ? "-retrieved-candidates-v1":"-selected-records-v1"))
    }
}

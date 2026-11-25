import Foundation
import IBrain

/// Explicit opt-in; legacy/default request bytes and receipt bindings remain.
public enum EvidenceTemporalScopePolicy: Sendable {
    case legacy, inventoryVsEventTimeV1
}

/// Separates record availability from the event-time restriction. This checks
/// semantic choice consistency; it never infers meaning by matching words or
/// rewrites a wrong answer. Coherent but wrong meaning still needs evaluation.
internal enum RecordInventoryTemporalScope {
    static func task(_ base: ChoiceTask, input: EvidenceQuestionInput) throws -> ChoiceTask {
        guard base.version == "photographed-evidence-question-v11", input.policy == .completeV9 else {
            throw SemanticError.unsupportedEvidence
        }
        var state = try JSONSerialization.jsonObject(with: Data(base.state.utf8)) as! [String: Any]
        var policies = state["nativePolicies"] as! [String: String]
        policies["temporalScope"] = "Current/remaining records, entries, saved photos and sources still available after Forget describe record inventory, not future event time. Inventory may contain past, cancelled, future and undated records. Status, source availability, event-time window and start-clock conditions are independent. Choose future only for requested future event-time meaning, never because a record remains saved or because now is later than its date. Full this-week is distinct from the remaining part of this week. These are source records, not a complete personal calendar."
        policies["inventory"] = (policies["inventory"] ?? "") + " This membership scope does not imply any event-date restriction."
        state["nativePolicies"] = policies
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys, .withoutEscapingSlashes])
        var questions = base.questions
        let window = questions["window"]!
        var windows = window.criteria
        windows["all"] = "All event dates: no temporal restriction, including supported past/future facts and useful undated records. Current/remaining record inventory alone uses this; it does not mean only future events."
        windows["upcoming"] = "Only requested future event time from the injected current instant onward, with no implicit week limit. Requires temporalMeaning upcoming; remaining stored records alone is insufficient."
        windows["remainingThisWeek"] = "The remaining portion of the current injected week, from now to week end. Requires temporalMeaning remainingWeek. Full this-week and remaining source records are different meanings."
        questions["window"] = ChoiceQuestion(window.instructions + " Keep this consistent with temporalMeaning. Never turn remaining available entries or current inventory into upcoming. A full calendar week retains its elapsed portion unless the human also requests futurity.", windows)
        var meanings = [
            "inventory": "No event-time restriction: all current available source-document entries, including surviving past/cancelled/future/undated records. Use window all. Availability/Forget and regardless-of-status are not future-event requests.",
            "upcoming": "The human requests future event time (coming up/from now onward), without a calendar-week limit. Use window upcoming.",
            "remainingWeek": "The human requests the rest of this week, or BOTH future/coming-up and this week. Use window remainingThisWeek.",
            "calendarWindow": "A full named/relative calendar window, such as today, this week, next week or a supplied month/year. Includes its elapsed portion unless explicitly restricted. Use its exact corresponding window, never upcoming or remainingThisWeek.",
            "referenceOnly": "Location, originals, printed details or comparison of actual referenced documents; no new event-time filtering operation. Use window all or inherit.",
            "unsupported": "The complete temporal request cannot be represented. Use unsupported operation; never drop a condition."
        ]
        if input.previous != nil {
            meanings["inherit"] = "Use only actual previous displayed membership and keep its existing date window. Use inventory previous and window inherit; never manufacture earlier context."
        }
        questions["temporalMeaning"] = ChoiceQuestion("Classify event-date meaning independently of which source records remain available, source status/kind and start-clock conditions. Remaining entries/photos after removal or Forget is inventory, not automatically future time. Interpret the whole human question and actual context, not a familiar word or the dates of candidate records. All current entries regardless of status has no time restriction unless the question separately requests one. Full this-week differs from rest-of-week. The native compiler checks consistency with window and inventory and will not repair a wrong pair.", meanings)
        return ChoiceTask(id: base.id, state: String(decoding: data, as: UTF8.self), questions: questions,
                          version: EvidenceQuestionSession.temporalScopeContractVersion)
    }

    static func validate(_ receipt: any DecisionChoiceReading, input: EvidenceQuestionInput) throws {
        let operation = try receipt.choice("operation")
        if operation == "unsupported" || operation == "clarify" { return }
        let meaning = try receipt.choice("temporalMeaning"), window = try receipt.choice("window")
        let filtering = ["list", "listScheduled", "listCancelled", "changes"].contains(operation)
        let inventory = input.previous == nil ? "current" : try receipt.choice("inventory")
        let valid: Bool
        switch meaning {
        case "inventory": valid = filtering && inventory == "current" && window == "all"
        case "upcoming": valid = filtering && window == "upcoming"
        case "remainingWeek": valid = filtering && window == "remainingThisWeek"
        case "calendarWindow": valid = filtering && !["all", "inherit", "upcoming", "remainingThisWeek"].contains(window)
        case "inherit": valid = filtering && input.previous != nil && inventory == "previous" && window == "inherit"
        case "referenceOnly": valid = !filtering && ["all", "inherit"].contains(window)
        default: valid = false
        }
        guard valid else { throw SemanticError.invalidReceipt }
    }
}

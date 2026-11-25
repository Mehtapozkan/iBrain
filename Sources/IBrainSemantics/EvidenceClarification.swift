import Foundation
import IBrain

/// Opt-in semantic reason selection; default request bytes remain unchanged.
public enum EvidenceClarificationPolicy: Sendable { case legacy, reasonV1 }

internal enum EvidenceClarification {
    static func task(_ base: ChoiceTask, input: EvidenceQuestionInput) throws -> ChoiceTask {
        guard input.policy == .completeV9,
              input.temporalScopePolicy == .inventoryVsEventTimeV1,
              base.version == EvidenceQuestionSession.temporalScopeContractVersion else {
            throw SemanticError.unsupportedEvidence
        }
        var questions = base.questions
        questions["clarificationReason"] = ChoiceQuestion(
            "Choose why clarification is necessary only when operation is clarify; otherwise choose none. " +
            "Use the actual question and displayed context, never keywords alone. An ordinal or pronoun cannot " +
            "refer to an invented earlier list. Missing source facts produce supported partial answers, not " +
            "clarification or ownership questions. Public/test provenance alone never makes an answer unavailable.",
            ["none": "Operation is not clarify.",
             "reference": "An item/list reference is missing or ambiguous in the actual context.",
             "authority": "The human explicitly asks to verify personal ownership, authenticity, current validity or complete personal calendar coverage beyond photo evidence.",
             "intent": "A necessary part of the human's intended request is ambiguous; not merely a missing printed fact or an unsupported operation."])
        return ChoiceTask(id: base.id, state: base.state, questions: questions, version: EvidenceQuestionSession.clarificationContractVersion)
    }

    static func validate(_ receipt: any DecisionChoiceReading) throws {
        let operation = try receipt.choice("operation")
        let reason = try receipt.choice("clarificationReason")
        guard operation == "clarify" ? ["reference", "authority", "intent"].contains(reason) : reason == "none" else {
            throw SemanticError.invalidReceipt
        }
    }

    static func message(_ receipt: any DecisionChoiceReading, input: EvidenceQuestionInput) throws -> String {
        switch try receipt.choice("clarificationReason") {
        case "reference":
            if input.previous == nil {
                return "There is no earlier displayed list or selected item to refer to. Which photographed event or document do you mean?"
            }
            if input.previous?.orderedRecordIDs.isEmpty == true && input.previous?.documentContext == nil {
                return "The displayed answer has no item to resolve that reference. Which photographed event or document do you mean?"
            }
            return "Which photographed event or document in the displayed answer do you mean?"
        case "authority":
            return "The photos can show printed details, but they cannot verify personal ownership, current validity or a complete personal calendar. Which photo-backed details would you like?"
        case "intent":
            return "Which detail or condition would you like me to answer about from the photographed documents?"
        default:
            throw SemanticError.invalidReceipt
        }
    }
}

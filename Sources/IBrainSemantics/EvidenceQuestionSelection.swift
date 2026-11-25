import Foundation
import IBrain

/// Native inspection of an actual displayed answer; no guessed IDs or scope replacement.
public enum EvidenceQuestionSelection {
    public static func selecting(recordID:String,in context:EvidenceQuestionContext,activeAnswerID:UUID,store:MemoryStore)async throws->EvidenceQuestionContext {
        guard context.answerID==activeAnswerID,let index=context.orderedRecordIDs.firstIndex(of:recordID)else{throw MemoryError.invalidContext}
        try await store.validate(context.snapshot.permit)
        return EvidenceQuestionContext(answerID:context.answerID,selectedOrdinal:index+1,pendingQuestion:context.pendingQuestion,orderedRecordIDs:context.orderedRecordIDs,orderedTitles:context.orderedTitles,snapshot:context.snapshot,window:context.window,submittedAt:context.submittedAt,calendar:context.calendar,predicateIssues:context.predicateIssues,documentContext:context.documentContext,startClockMeaning:context.startClockMeaning,literalPredicates:context.literalPredicates,recordScope:context.recordScope)
    }
}

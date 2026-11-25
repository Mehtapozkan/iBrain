import Foundation
import IBrain

/// Pin consumer extension: a real native inspection selects only an item in
/// this exact still-current displayed answer. It grants no write authority.
/// This is a local extension to pinned Core0.20, not an upstream API claim.
public enum EvidenceQuestionHostInspection {
    /// Read the exact native window used by the SDK; the host need not reparse
    /// the question or render a printed-Gregorian boundary in the wrong zone.
    public static func window(in context:EvidenceQuestionContext)->QueryWindow{context.window.window}
    public static func submittedAt(in context:EvidenceQuestionContext)->Date{context.submittedAt}
    public static func displayTimeZone(in context:EvidenceQuestionContext)->TimeZone{context.window.printedCalendar ? TimeZone(secondsFromGMT:0)!:context.calendar.timeZone}
    public static func selecting(recordID:String,in context:EvidenceQuestionContext,activeAnswerID:UUID,store:MemoryStore)async throws->EvidenceQuestionContext {
        guard context.answerID==activeAnswerID,let index=context.orderedRecordIDs.firstIndex(of:recordID)else{throw MemoryError.invalidContext}
        try await store.validate(context.snapshot.permit)
        return EvidenceQuestionContext(answerID:context.answerID,selectedOrdinal:index+1,pendingQuestion:context.pendingQuestion,orderedRecordIDs:context.orderedRecordIDs,orderedTitles:context.orderedTitles,snapshot:context.snapshot,window:context.window,submittedAt:context.submittedAt,calendar:context.calendar,predicateIssues:context.predicateIssues,documentContext:context.documentContext,startClockMeaning:context.startClockMeaning,literalPredicates:context.literalPredicates,recordScope:context.recordScope)
    }
}

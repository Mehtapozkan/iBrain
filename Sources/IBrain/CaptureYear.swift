import Foundation

public enum InferredDatePolicy: String, Sendable { case explicitOnly, labelledCaptureYear, labelledTemporalContext }

/// Opt-in host policy. The host attests that the timestamp is ORIGINAL
/// capture, not import/current/GPS metadata. No effects are authorized here.
public enum CaptureYearPolicy {
    public static let version = "original-capture-year/1"
    public static func propose(printed: EventDate, originalCaptureSource source: SourceSnapshot, printedWeekday: Int? = nil) -> EventDate? {
        guard printed.year == nil, printed.certainty == .explicit, let capturedAt = source.capturedAt,
              let year = year(month: printed.month, day: printed.day, zoneID: printed.timeZoneID, capturedAt: capturedAt, weekday: printedWeekday) else { return nil }
        return EventDate(year: year, month: printed.month, day: printed.day, hour: printed.hour, minute: printed.minute,
            timeZoneID: printed.timeZoneID, utcOffsetSeconds: printed.utcOffsetSeconds, certainty: .inferred,
            captureYearDerivation: CaptureYearDerivation(policyVersion: version, source: source.reference, originalCapturedAt: capturedAt, printedWeekday: printedWeekday),
            printedDateText: printed.printedDateText, printedTimeText: printed.printedTimeText)
    }
    internal static func validates(_ date: EventDate) -> Bool {
        guard date.certainty == .inferred, let proof = date.captureYearDerivation, proof.policyVersion == version else { return false }
        guard let resolved = year(month: date.month, day: date.day, zoneID: date.timeZoneID, capturedAt: proof.originalCapturedAt, weekday: proof.printedWeekday) else { return false }
        return date.year == resolved
    }
    private static func year(month: Int?, day: Int?, zoneID: String?, capturedAt: Date, weekday: Int?) -> Int? {
        guard let month, let day, (1...12).contains(month), (1...31).contains(day),
              let zoneID, let zone = TimeZone(identifier: zoneID), weekday.map({ (1...7).contains($0) }) ?? true else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let captureDay = calendar.startOfDay(for: capturedAt), captureYear = calendar.component(.year, from: captureDay)
        let candidates = ((captureYear - 1)...(captureYear + 1)).compactMap { candidate -> (Int, Int)? in
            let components = DateComponents(year: candidate, month: month, day: day)
            guard let date = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: date) == components,
                  weekday.map({ calendar.component(.weekday, from: date) == $0 }) ?? true,
                  let days = calendar.dateComponents([.day], from: captureDay, to: date).day, abs(days) <= 183 else { return nil }
            return (candidate, abs(days))
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
        guard let nearest = candidates.first, candidates.count == 1 || candidates[1].1 - nearest.1 > 14 else { return nil }
        return nearest.0
    }
}

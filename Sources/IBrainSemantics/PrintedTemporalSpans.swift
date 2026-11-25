import Foundation

/// Opt-in v2 grammar. It augments native proposals; only a bound semantic
/// receipt establishes event roles. It never repairs ambiguous OCR digits.
internal enum PrintedTemporalSpans {
    static func spans(in lines: [ObservedLine], dottedMeridiemClocks: Bool = false) throws -> [TemporalEvidenceSpan] {
        var result = try AnchoredTemporalObservation.spans(in: lines)
        let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        let dayFirst = #"(?<![\p{L}\p{N}])(?:(Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sun|Mon|Tue|Wed|Thu|Fri|Sat)(?:,\s*|\s+))?([0-9]{1,2})(?:st|nd|rd|th)?\s*(January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)(?:,?\s+([0-9]{4})|,([0-9]{4}))?(?![\p{L}\p{N}])"#
        let legacyMeridiem = #"(?<![\p{L}\p{N}:])(?<![0-9]\.)([0-9]{1,2})(?::([0-9]{2}))?\s*([ap])\.?\s*m\.?(?![\p{L}\p{N}:])"#
        let meridiem = dottedMeridiemClocks ? legacyMeridiem.replacingOccurrences(of: #"(?::([0-9]{2}))?"#, with: #"(?:[.:]([0-9]{2}))?"#).replacingOccurrences(of: #"(?![\p{L}\p{N}:])"#, with: #"(?![\p{L}\p{N}:.])"#) : legacyMeridiem
        var matcher=TemporalPatternMatcher()
        func matches(_ pattern: String, _ text: String) throws -> [NSTextCheckingResult] {
            try matcher.matches(pattern,in:text)
        }
        for line in lines {
            func value(_ match: NSTextCheckingResult, _ group: Int) -> String {
                Range(match.range(at: group), in: line.text).map { String(line.text[$0]) } ?? ""
            }
            for m in try matches(dayFirst, line.text) {
                let name = value(m, 3).lowercased()
                guard let month = months.firstIndex(where: { $0 == name || $0.prefix(3) == name || ($0 == "september" && name == "sept") }).map({ $0 + 1 }),
                      let day = Int(value(m, 2)), day > 0 else { continue }
                let year = Int(value(m, 4).isEmpty ? value(m, 5) : value(m, 4))
                let leap = year.map { $0 % 400 == 0 || ($0 % 4 == 0 && $0 % 100 != 0) } ?? true
                guard year.map({ (1...9999).contains($0) }) ?? true,
                      day <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1],
                      let range = Range(m.range, in: line.text) else { continue }
                if year == nil, String(line.text[range.upperBound...]).range(of: #"^\s*,?\s*[0-9]+(?:\s|$)"#, options: .regularExpression) != nil { continue }
                let weekday = value(m, 1).lowercased()
                if let year, !weekday.isEmpty {
                    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                          weekdays[calendar.component(.weekday, from: date) - 1] == String(weekday.prefix(3)) else { continue }
                }
                result.append(TemporalEvidenceSpan(id: "", kind: .date, observationID: line.id,
                    utf16Location: m.range.location, utf16Length: m.range.length, quote: String(line.text[range]),
                    date: .init(year: year, month: month, day: day), time: nil, zone: nil))
            }
            for m in try matches(meridiem, line.text) {
                guard let h = Int(value(m, 1)), (1...12).contains(h),
                      let minute = Int(value(m, 2).isEmpty ? "0" : value(m, 2)), (0...59).contains(minute),
                      let range = Range(m.range, in: line.text) else { continue }
                // Replace an overlapping legacy clock (e.g. 08:30 in 08:30p.m.).
                result.removeAll { $0.observationID == line.id && $0.kind == .time && NSIntersectionRange(NSRange(location: $0.utf16Location, length: $0.utf16Length), m.range).length > 0 }
                result.append(TemporalEvidenceSpan(id: "", kind: .time, observationID: line.id,
                    utf16Location: m.range.location, utf16Length: m.range.length, quote: String(line.text[range]),
                    date: nil, time: .init(hour: h % 12 + (value(m, 3).lowercased() == "p" ? 12 : 0), minute: minute), zone: nil))
            }
        }
        let observations = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0.text) })
        result = try result.map { span in
            guard span.kind == .time, let text = observations[span.observationID],
                  let range = Range(NSRange(location: span.utf16Location, length: span.utf16Length), in: text) else { return span }
            let prefix = String(text[..<range.lowerBound])
            let approximate = try matches(#"(?:\b(?:approx(?:imately)?\.?|around|about)|~)\s*$"#, prefix).last
            guard let approximate else { return span }
            let expanded = NSRange(location: approximate.range.location, length: span.utf16Location + span.utf16Length - approximate.range.location)
            guard let whole = Range(expanded, in: text) else { throw SemanticError.unsupportedEvidence }
            return TemporalEvidenceSpan(id: "", kind: .time, observationID: span.observationID,
                utf16Location: expanded.location, utf16Length: expanded.length, quote: String(text[whole]),
                date: nil, time: span.time, zone: nil, timeQualifier: .approximate)
        }
        guard result.count <= AnchoredTemporalObservation.maximumSpans else { throw SemanticError.unsupportedEvidence }
        let order = Dictionary(uniqueKeysWithValues: lines.enumerated().map { ($0.element.id, $0.offset) })
        result.sort { (order[$0.observationID]!, $0.utf16Location, $0.kind.rawValue) < (order[$1.observationID]!, $1.utf16Location, $1.kind.rawValue) }
        return result.enumerated().map { index, span in
            TemporalEvidenceSpan(id: String(format: "s%03d", index), kind: span.kind, observationID: span.observationID,
                utf16Location: span.utf16Location, utf16Length: span.utf16Length, quote: span.quote,
                date: span.date, time: span.time, zone: span.zone, timeQualifier: span.timeQualifier)
        }
    }
}

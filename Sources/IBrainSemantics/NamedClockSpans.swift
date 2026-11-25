import Foundation

/// V9 only. Literal clock candidates still require a semantic role receipt.
/// A named clock in a title, venue or deadline is not automatically event start.
internal enum NamedClockSpans {
    static func spans(in lines: [ObservedLine]) throws -> [TemporalEvidenceSpan] {
        var result = try AnchoredTemporalObservation.spans(in: lines, policy: .anchoredSpansV8)
        let pattern = #"(?<![\p{L}\p{N}:.,/])(?:12(?::00)?\s*)?(noon|midnight)(?![\p{L}\p{N}])"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        for line in lines {
            for match in regex.matches(in: line.text, range: NSRange(line.text.startIndex..., in: line.text)) {
                guard let range = Range(match.range, in: line.text),
                      let word = Range(match.range(at: 1), in: line.text) else { continue }
                let prefix = String(line.text[..<range.lowerBound])
                // Do not rescue a suffix from unsupported or contradictory
                // numeric expressions such as 11 noon, 12:30 noon or 12 PM midnight.
                if !line.text[range].hasPrefix("12"), prefix.range(of: #"(?<![\p{L}\p{N}])(?:[0-9]{1,2}(?:[:.][0-9]{1,2})?(?:\s*[AP]\.?M\.?)?|[AP]\.?M\.?)\s*$"#,
                                options: [.regularExpression, .caseInsensitive]) != nil { continue }
                var selected = match.range
                var qualifier: TemporalEvidenceSpan.TimeQualifier?
                let approximate = try NSRegularExpression(pattern: #"\b(?:about|around|approximately|approx\.?|circa|ca\.)\s*$"#, options: .caseInsensitive)
                if let prior = approximate.matches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)).last {
                    selected = NSRange(location: prior.range.location, length: match.range.location + match.range.length - prior.range.location)
                    qualifier = .approximate
                }
                guard let quoteRange = Range(selected, in: line.text) else { throw SemanticError.unsupportedEvidence }
                result.append(TemporalEvidenceSpan(id: "", kind: .time, observationID: line.id,
                    utf16Location: selected.location, utf16Length: selected.length, quote: String(line.text[quoteRange]),
                    date: nil, time: .init(hour: line.text[word].lowercased() == "noon" ? 12 : 0, minute: 0),
                    zone: nil, timeQualifier: qualifier))
            }
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

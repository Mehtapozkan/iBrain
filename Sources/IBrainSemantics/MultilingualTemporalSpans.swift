import Foundation

/// Opt-in bounded grammar. Native values remain proposals until a semantic
/// receipt assigns their role. No locale, capture date, century or zone guessing.
internal enum MultilingualTemporalSpans {
    private static let monthWords = [
        ["januar", "jan", "janvier", "janv"], ["februar", "feb", "février", "fevrier", "févr", "fevr"],
        ["märz", "maerz", "mär", "mars"], ["april", "apr", "avril", "avr"], ["mai"],
        ["juni", "jun", "juin"], ["juli", "jul", "juillet", "juil"], ["august", "aug", "août", "aout"],
        ["september", "sept", "septembre"], ["oktober", "okt", "octobre", "oct"],
        ["november", "nov", "novembre"], ["dezember", "dez", "décembre", "decembre", "déc", "dec"]]
    private static let weekdayWords = [
        ["sunday", "sun", "sonntag", "so", "dimanche", "dim"],
        ["monday", "mon", "montag", "mo", "lundi", "lun"],
        ["tuesday", "tue", "dienstag", "di", "mardi", "mar"],
        ["wednesday", "wed", "mittwoch", "mi", "mercredi", "mer"],
        ["thursday", "thu", "donnerstag", "do", "jeudi", "jeu"],
        ["friday", "fri", "freitag", "fr", "vendredi", "ven"],
        ["saturday", "sat", "samstag", "sa", "samedi", "sam"]]
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).replacingOccurrences(of: ".", with: "")
    }
    private static func valid(year: Int?, month: Int, day: Int) -> Bool {
        guard (1...12).contains(month), day > 0, year.map({ (1...9999).contains($0) }) ?? true else { return false }
        let leap = year.map { $0 % 400 == 0 || ($0 % 4 == 0 && $0 % 100 != 0) } ?? true
        return day <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    }
    static func spans(in lines: [ObservedLine], frenchMorningClocks: Bool = false, hourOnlyUhr: Bool = false, dottedMeridiemClocks: Bool = false, germanLabelledClocks: Bool = false, naturalTicketFormats: Bool = false, labelledColonClocks: Bool = false, explicitColonUnits:Bool = false) throws -> [TemporalEvidenceSpan] {
        var result = try PrintedTemporalSpans.spans(in: lines, dottedMeridiemClocks: dottedMeridiemClocks)
        var matcher=TemporalPatternMatcher()
        func matches(_ pattern: String, _ text: String) throws -> [NSTextCheckingResult] {
            try matcher.matches(pattern,in:text)
        }
        if labelledColonClocks {
            // Lexical clock boundaries are independent of the label language.
            // A preceding colon is a field separator unless it continues a
            // numeric clock; exact role remains a semantic decision.
            let legacyPattern = #"(?<![\p{L}\p{N}])([0-9]{1,2}):([0-9]{2})(?:\s*([AP])\.?M\.?)?(?![\p{L}\p{N}:])"#
            let unitPattern = #"(?<![\p{L}\p{N}])([0-9]{1,2}):([0-9]{2})(?:\s*([AP])\.?M\.?)?(?:\s*(h|Uhr))?(?![\p{L}\p{N}:])"#
            let pattern = explicitColonUnits ? unitPattern:legacyPattern
            for line in lines {
                for match in try matches(pattern,line.text) {
                    guard let range=Range(match.range,in:line.text),let hr=Range(match.range(at:1),in:line.text),let mr=Range(match.range(at:2),in:line.text),let hour=Int(line.text[hr]),let minute=Int(line.text[mr]),(0...59).contains(minute)else{continue}
                    let prefix=String(line.text[..<range.lowerBound])
                    if prefix.range(of:#"(?:[0-9]\s*:\s*|[<>=≤≥+−]\s*)$"#,options:.regularExpression) != nil {result.removeAll{$0.observationID==line.id && $0.kind == .time && NSIntersectionRange(NSRange(location:$0.utf16Location,length:$0.utf16Length),match.range).length>0};continue}
                    let suffix=String(line.text[range.upperBound...])
                    if suffix.range(of:#"^\s*:\s*[0-9]"#,options:.regularExpression) != nil {continue}
                    let meridiem=Range(match.range(at:3),in:line.text).map{String(line.text[$0]).uppercased()}
                    guard meridiem == nil ? (0...23).contains(hour):(1...12).contains(hour)else{continue}
                    if explicitColonUnits {
                        let unit=Range(match.range(at:4),in:line.text).map{String(line.text[$0])}
                        guard meridiem == nil || unit == nil else{continue}
                        // A colon/field label alone does not establish AM/PM.
                        // Preserve baseline explicit 24h forms and printed units.
                        let rawHour=String(line.text[hr])
                        guard meridiem != nil || unit != nil || hour>12 || hour==0 || (rawHour.count==2 && rawHour.first=="0") else{continue}
                    }
                    if result.contains(where:{$0.observationID==line.id && $0.kind == .time && NSIntersectionRange(NSRange(location:$0.utf16Location,length:$0.utf16Length),match.range).length>0}) {continue}
                    result.append(TemporalEvidenceSpan(id:"",kind:.time,observationID:line.id,utf16Location:match.range.location,utf16Length:match.range.length,quote:String(line.text[range]),date:nil,time:.init(hour:meridiem.map{hour%12+($0=="P" ? 12:0)} ?? hour,minute:minute),zone:nil))
                }
            }
        }
        let supportedMonths=monthWords.enumerated().map{index,words in naturalTicketFormats && index==4 ? words+["may"]:words}
        let monthPattern = supportedMonths.flatMap { $0 }.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let weekdayPattern = weekdayWords.flatMap { $0 }.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let yearMarker = germanLabelledClocks ? #"['’‘]?"# : ""
        let named = #"(?<![\p{L}\p{N}/.-])([0-9]{1,2})[.\s]*("# + monthPattern + #")\.?(?:[.\s]*"# + yearMarker + #"([0-9]{4}|[0-9]{2}))?(?![\p{L}\p{N}/.-])"#
        let numeric = #"(?<![\p{L}\p{N}/.-])([0-9]{1,2})([./-])([0-9]{1,2})\2([0-9]{4}|[0-9]{2})(?![\p{L}\p{N}/.-])"#
        let numericWithPunctuation = hourOnlyUhr ? numeric.replacingOccurrences(of:#"(?![\p{L}\p{N}/.-])"#,with:#"\.?(?![\p{L}\p{N}/.-])"#):numeric
        let explicitClock = #"(?<![\p{L}\p{N}:.,])([0-9]{1,2})(?:\s*[h]\s*([0-9]{2})|\.([0-9]{2})\s*Uhr)(?![\p{L}\p{N}:.,])"#
        let weekdayPrefix = #"(?<![\p{L}])("# + weekdayPattern + #")\.?\s*,?\s*$"#
        for line in lines {
            func part(_ match: NSTextCheckingResult, _ group: Int) -> String {
                Range(match.range(at: group), in: line.text).map { String(line.text[$0]) } ?? ""
            }
            func weekday(before range: NSRange) throws -> (Int, NSRange)? {
                guard let r = Range(range, in: line.text) else { return nil }
                let prefix = String(line.text[..<r.lowerBound])
                guard let m = try matches(weekdayPrefix, prefix).last, let word = Range(m.range(at: 1), in: prefix),
                      let index = weekdayWords.firstIndex(where: { $0.map(normalized).contains(normalized(String(prefix[word]))) }) else { return nil }
                return (index + 1, m.range)
            }
            func agrees(_ date: TemporalEvidenceSpan.DateValue, _ weekday: Int?) -> Bool {
                guard let weekday, let year = date.year else { return true }
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                guard let instant = calendar.date(from: DateComponents(year: year, month: date.month, day: date.day)) else { return false }
                return calendar.component(.weekday, from: instant) == weekday
            }
            func removeOverlappingDates(_ range: NSRange) {
                result.removeAll { $0.observationID == line.id && $0.kind == .date && NSIntersectionRange(NSRange(location: $0.utf16Location, length: $0.utf16Length), range).length > 0 }
            }
            // Foreign weekday context must not be discarded by a legacy match.
            var rejected: [NSRange] = []
            for span in result where span.observationID == line.id && span.kind == .date {
                let r = NSRange(location: span.utf16Location, length: span.utf16Length)
                if let d = span.date, let w = try weekday(before: r), !agrees(d, w.0) { rejected.append(r) }
            }
            for range in rejected { removeOverlappingDates(range) }
            for m in try matches(named, line.text) {
                let range = m.range; removeOverlappingDates(range)
                guard let day = Int(part(m, 1)), let month = supportedMonths.firstIndex(where: { $0.map(normalized).contains(normalized(part(m, 2))) }).map({ $0 + 1 }) else { continue }
                let token = part(m, 3), year = token.count == 4 ? Int(token) : nil
                guard valid(year: year, month: month, day: day) else { continue }
                let w = try weekday(before: range), d = TemporalEvidenceSpan.DateValue(year: year, month: month, day: day, printedYearToken: token.count == 2 ? token : nil)
                guard agrees(d, w?.0), let r = Range(range, in: line.text) else { continue }
                // Reject a partial match that would erase another visible year.
                let visibleYearFragment = germanLabelledClocks ? #"^\s*[.,]?['’‘]?\s*[0-9]+"# : #"^\s*[.,]?\s*[0-9]+(?:\s|$)"#
                if token.isEmpty, String(line.text[r.upperBound...]).range(of: visibleYearFragment, options: .regularExpression) != nil { continue }
                let whole = w.map { NSRange(location: $0.1.location, length: range.location + range.length - $0.1.location) } ?? range
                guard let q = Range(whole, in: line.text) else { throw SemanticError.unsupportedEvidence }
                result.append(TemporalEvidenceSpan(id: "", kind: .date, observationID: line.id, utf16Location: whole.location, utf16Length: whole.length,
                    quote: String(line.text[q]), date: d, time: nil, zone: nil))
            }
            if naturalTicketFormats {
                let fused = #"(?<![\p{L}\p{N}])(SUN|MON|TUE|WED|THU|FRI|SAT)(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)\s+([0-9]{1,2})[ ,]+([0-9]{4})(?![\p{L}\p{N}])"#
                for m in try matches(fused,line.text) {
                    let englishMonths=["jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec"]
                    let weekdays=["sun","mon","tue","wed","thu","fri","sat"]
                    guard let month=englishMonths.firstIndex(of:part(m,2).lowercased()).map({$0+1}),let day=Int(part(m,3)),let year=Int(part(m,4)),valid(year:year,month:month,day:day),let w=weekdays.firstIndex(of:part(m,1).lowercased()),let q=Range(m.range,in:line.text) else{continue}
                    let d=TemporalEvidenceSpan.DateValue(year:year,month:month,day:day)
                    guard agrees(d,w+1) else{continue}
                    removeOverlappingDates(m.range)
                    result.append(TemporalEvidenceSpan(id:"",kind:.date,observationID:line.id,utf16Location:m.range.location,utf16Length:m.range.length,quote:String(line.text[q]),date:d,time:nil,zone:nil))
                }
            }
            for m in try matches(numericWithPunctuation, line.text) {
                removeOverlappingDates(m.range)
                guard let first = Int(part(m, 1)), let second = Int(part(m, 3)) else { continue }
                let token = part(m, 4), year = token.count == 4 ? Int(token) : nil, w = try weekday(before: m.range)
                var possibilities = Set<TemporalEvidenceSpan.DateValue>()
                // A dot-separated date with an explicit German weekday uses the
                // printed German day.month convention; no century is chosen.
                let germanWeekday = naturalTicketFormats && part(m,2)=="." && w != nil && Range(m.range,in:line.text).map { r in
                    String(line.text[..<r.lowerBound]).range(of:#"(?:Sonntag|Montag|Dienstag|Mittwoch|Donnerstag|Freitag|Samstag)\s*,?\s*$"#,options:[.regularExpression,.caseInsensitive]) != nil
                } == true
                let components = germanWeekday ? [(second,first)]:[(first, second), (second, first)]
                for (month, day) in components where valid(year: year, month: month, day: day) {
                    let d = TemporalEvidenceSpan.DateValue(year: year, month: month, day: day, printedYearToken: token.count == 2 ? token : nil)
                    if agrees(d, w?.0) { possibilities.insert(d) }
                }
                guard possibilities.count == 1, let d = possibilities.first else { continue }
                let whole = w.map { NSRange(location: $0.1.location, length: m.range.location + m.range.length - $0.1.location) } ?? m.range
                guard let q = Range(whole, in: line.text) else { throw SemanticError.unsupportedEvidence }
                result.append(TemporalEvidenceSpan(id: "", kind: .date, observationID: line.id, utf16Location: whole.location, utf16Length: whole.length,
                    quote: String(line.text[q]), date: d, time: nil, zone: nil))
            }
            if hourOnlyUhr {
                // Uhr explicitly marks a 24-hour civil clock. Do not recover
                // a suffix from malformed minute/decimal/time/range tokens.
                let pattern = #"(?<![\p{L}\p{N}:.,/\-])([0-9]{1,2})\s*Uhr(?![\p{L}\p{N}])"#
                for m in try matches(pattern,line.text) {
                    guard let hour=Int(part(m,1)),(0...23).contains(hour),let range=Range(m.range,in:line.text)else{continue}
                    let prefix=String(line.text[..<range.lowerBound]),suffix=String(line.text[range.upperBound...])
                    // An inequality or OCR glyph attached to a numeric suffix
                    // is not the literal midnight token. Do not guess the digit.
                    if naturalTicketFormats,prefix.range(of:#"[<>=≤≥+−]\s*$"#,options:.regularExpression) != nil {continue}
                    if prefix.range(of:#"(?<![0-9])[0-9]{1,2}\s*[:.,/\-]\s*$"#,options:.regularExpression) != nil || suffix.range(of:#"^\s*(?:[:.,]\s*[0-9]|[AP]\.?M\.?\b|[–-]\s*[0-9])"#,options:[.regularExpression,.caseInsensitive]) != nil {continue}
                    result.append(TemporalEvidenceSpan(id:"",kind:.time,observationID:line.id,utf16Location:m.range.location,utf16Length:m.range.length,quote:String(line.text[range]),date:nil,time:.init(hour:hour,minute:0),zone:nil))
                }
            }
            for m in try matches(explicitClock, line.text) {
                let hourText = part(m, 1)
                guard let hour = Int(hourText), let minute = Int(part(m, 2).isEmpty ? part(m, 3) : part(m, 2)),
                      (0...23).contains(hour), (0...59).contains(minute),
                      (frenchMorningClocks && !part(m, 2).isEmpty) || hour > 12 || hour == 0 || hourText.hasPrefix("0"),
                      let r = Range(m.range, in: line.text) else { continue }
                // French h notation explicitly supplies a 24-hour clock, including
                // unpadded morning hours. Mixed h + AM/PM remains unsupported.
                if frenchMorningClocks, !part(m, 2).isEmpty, String(line.text[r.upperBound...]).range(of: #"^\s*(?:A\.?M\.?|P\.?M\.?)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { continue }
                result.append(TemporalEvidenceSpan(id: "", kind: .time, observationID: line.id, utf16Location: m.range.location, utf16Length: m.range.length,
                    quote: String(line.text[r]), date: nil, time: .init(hour: hour, minute: minute), zone: nil))
            }
            if germanLabelledClocks {
                // A German clock label distinguishes hh.mm from prices and
                // decimal/date fragments. Keep the label in the exact span so
                // preceding approximation text remains attached below. A role
                // decision is still required: Einlass is not an event start.
                let labelled = #"(?<![\p{L}\p{N}])(?:Beginn|Einlass|Einlaß)\s*:?\s*([0-9]{1,2})\.([0-9]{2})(?![\p{L}\p{N}:.,/\-])"#
                for m in try matches(labelled, line.text) {
                    guard let hour = Int(part(m, 1)), let minute = Int(part(m, 2)),
                          (0...23).contains(hour), (0...59).contains(minute),
                          let range = Range(m.range, in: line.text) else { continue }
                    let suffix = String(line.text[range.upperBound...])
                    if suffix.range(of: #"^\s*(?:[AP]\.?M\.?\b|[–—−-]\s*[0-9]|[:.,]\s*[0-9])"#,
                                    options: [.regularExpression, .caseInsensitive]) != nil { continue }
                    result.append(TemporalEvidenceSpan(id: "", kind: .time, observationID: line.id,
                        utf16Location: m.range.location, utf16Length: m.range.length,
                        quote: String(line.text[range]), date: nil,
                        time: .init(hour: hour, minute: minute), zone: nil))
                }
            }
        }
        let texts = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0.text) })
        result = try result.map { span in
            guard span.kind == .time, span.timeQualifier == nil, let text = texts[span.observationID],
                  let r = Range(NSRange(location: span.utf16Location, length: span.utf16Length), in: text),
                  let m = try matches(#"(?:\b(?:ca\.|circa|ungefähr|etwa|vers|environ))\s*$"#, String(text[..<r.lowerBound])).last else { return span }
            let whole = NSRange(location: m.range.location, length: span.utf16Location + span.utf16Length - m.range.location)
            guard let q = Range(whole, in: text) else { throw SemanticError.unsupportedEvidence }
            return TemporalEvidenceSpan(id: "", kind: .time, observationID: span.observationID, utf16Location: whole.location, utf16Length: whole.length,
                quote: String(text[q]), date: nil, time: span.time, zone: nil, timeQualifier: .approximate)
        }
        guard result.count <= AnchoredTemporalObservation.maximumSpans else { throw SemanticError.unsupportedEvidence }
        let order = Dictionary(uniqueKeysWithValues: lines.enumerated().map { ($0.element.id, $0.offset) })
        result.sort { (order[$0.observationID]!, $0.utf16Location, $0.kind.rawValue) < (order[$1.observationID]!, $1.utf16Location, $1.kind.rawValue) }
        return result.enumerated().map { i, span in TemporalEvidenceSpan(id: String(format: "s%03d", i), kind: span.kind, observationID: span.observationID,
            utf16Location: span.utf16Location, utf16Length: span.utf16Length, quote: span.quote, date: span.date, time: span.time, zone: span.zone, timeQualifier: span.timeQualifier) }
    }
}

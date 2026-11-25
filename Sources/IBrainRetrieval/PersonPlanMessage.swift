import Foundation
import IBrain

/// One bounded, source-backed observation of a person's participation in a plan.
/// Message dates order an explicit correction and never supply the event date.
public struct PersonPlanMessage: Equatable, Sendable {
    public static let version = "person-plan-message-v4"
    public enum Participation: String, Sendable { case confirmed, tentative, unclear, withdrawn }

    public let source: SourceReference
    public let scope: MemoryScope
    public let person: String
    public let title: PersonPlanText
    public let eventDate: PersonPlanText
    public let eventTime: PersonPlanText?
    public let participation: Participation
    public let participationEvidence: [EvidenceAnchor]
    public let sentDate: PersonPlanText?
    public let sender: PersonPlanText?
    public let correction: [EvidenceAnchor]
    public let referencedSentDate: PersonPlanText?
    fileprivate let occurrenceDay: Date
    fileprivate let sentDay: Date?

    /// Interprets a single plan message whose proposed title is also printed
    /// as a standalone heading. All admission and join keys come from the
    /// current source. Unknown layouts remain outside this narrow reader.
    public static func read(proposedTitle: String, person: String, from source: SourceSnapshot) -> Self? {
        let printed = source.observations.filter { $0.kind == .text }
        guard (1...40).contains(printed.count) else { return nil }
        let lines = currentMessageLines(printed)
        guard (1...40).contains(lines.count), person.utf8.count <= 160, !person.isEmpty,
              proposedTitle.utf8.count <= 300, !proposedTitle.isEmpty,
              let heading = unique(lineValues(lines, source: source, pattern: "^(" +
                NSRegularExpression.escapedPattern(for: proposedTitle) + ")$")) else { return nil }
        // Administrative headings can label the document instead of the
        // occurrence. The shorter title also needs literal body support.
        let title: PersonPlanText
        if let bodyTitle = occurrenceTitle(inAdministrativeHeading: heading.value),
           let supportedTitle = unique(fragments(lines, source: source,
                pattern: #"\b("# + NSRegularExpression.escapedPattern(for: bodyTitle) + #")(?=[.!?,:]|\s+on\b|$)"#)
                .filter({ $0.evidence != heading.evidence })) {
            title = supportedTitle
        } else {
            guard fragments(lines, source: source, pattern: "(" +
                NSRegularExpression.escapedPattern(for: heading.value) + ")")
                .contains(where: { $0.evidence != heading.evidence }) else { return nil }
            title = heading
        }
        let escaped = NSRegularExpression.escapedPattern(for: person)
        let name = #"(?<![\p{L}\p{M}\p{N}'’\-])"# + escaped + #"(?![\p{L}\p{M}\p{N}'’\-])"#
        let leadingEnvelope = Array(lines.prefix(while: { $0.id != heading.evidence.first?.observationID }))
        let headedEnvelope = Array(lines.prefix(4)).filter { $0.id != heading.evidence.first?.observationID }
        let inlineFrom = #"^From\s+(.+?)\s+on\s+(?:"# + fullDatePattern + #")$"#
        let inlineDate = #"^From\s+.+?\s+on\s+("# + fullDatePattern + ")$"
        let inlineAuthors = lineValues(headedEnvelope, source: source, pattern: inlineFrom)
        let isolatedFrom = #"^From\s+((?!.*\son\s+(?:"# + fullDatePattern + #")$).+)$"#
        let sender = unique(inlineAuthors +
            lineValues(leadingEnvelope, source: source, pattern: isolatedFrom) +
            lineValues(lines, source: source, pattern: #"^Message from\s+(.+)$"#))
        let dateLines = lineValues(lines, source: source, pattern: #"^Sent\s+("# + fullDatePattern + ")$")
        let sent = unique(dateLines + lineValues(headedEnvelope, source: source, pattern: inlineDate))
        let messageHeaderIDs = Set((inlineAuthors + dateLines + [sender].compactMap { $0 })
            .flatMap { $0.evidence.map(\.observationID) })
        let body = lines.filter { !messageHeaderIDs.contains($0.id) }
        let cues: [(Participation, String)] = [
            (.confirmed, #"("# + name + #"\s+(?:(?:replied|said|texted|answered) yes\b|confirmed\b|accepted the invitation\b|will (?:join|attend)\b))"#),
            (.tentative, #"("# + name + #"\s+(?:(?:might|may|could) (?:join|attend|come)\b|can only (?:make|join|attend)\b))"#),
            (.withdrawn, #"("# + name + #"\s+(?:(?:can no longer|won['’]t|will not|cannot|can['’]t) (?:join|attend|come)\b|has withdrawn\b))"#)
        ]
        var supported: [Participation: [EvidenceAnchor]] = [:]
        for (status, pattern) in cues {
            supported[status] = uniqueAnchors(fragments(body, source: source, pattern: pattern).flatMap(\.evidence))
        }
        if let sender, planKey(sender.value) == planKey(person) {
            let statements: [(Participation, String)] = [
                (.confirmed, #"^(I(?:['’]m| am) in(?:[.!]?| (?:for|if|unless)\b.*)|Count me in\b.*|I (?:accept(?:ed)? the invitation|will attend|will join)\b.*)$"#),
                (.tentative, #"^(I (?:might|may|could) (?:join|attend|come)\b.*|I can (?:join|attend|come)\b.*\bif\b.*|I(?:['’]m| am) (?:thinking about|considering) (?:joining|attending|coming)\b.*)$"#),
                (.withdrawn, #"^(I (?:can no longer|won['’]t|will not|cannot|can['’]t) (?:join|attend|come|make)\b.*|I (?:have )?withdrawn?\b.*)$"#)
            ]
            for (status, pattern) in statements {
                for match in lineValues(body, source: source, pattern: pattern) {
                    let hasCondition = match.value.range(of: #"\b(?:if|unless|provided that)\b"#,
                        options: [.regularExpression, .caseInsensitive]) != nil
                    let qualifiedStatus = hasCondition ? Participation.tentative : status
                    supported[qualifiedStatus] = uniqueAnchors((supported[qualifiedStatus] ?? []) +
                        match.evidence + sender.evidence)
                }
            }
        }
        let stated = supported.filter { !$0.value.isEmpty }
        guard !stated.isEmpty else { return nil }
        let status = stated.count == 1 ? (stated.keys.first ?? .unclear) : .unclear
        let eventLines = body.filter { !$0.value.lowercased().hasPrefix("correction to ") }
        let timePattern = #"[0-9]{1,2}(?::[0-9]{2})?\s+[ap]m"#
        let dateInSentence = #"\b(?:on|is)\s+("# + fullDatePattern + #")\b"#
        let bodyDates = fragments(eventLines, source: source, pattern: dateInSentence)
        let dateHeadings = lineValues(eventLines, source: source, pattern: #"^(?:Ideas for\s+)?("# +
            fullDatePattern + #")(?:\s+at\s+(?:"# + timePattern + #"))?[.]?$"#)
        guard let date = unique(bodyDates.isEmpty ? dateHeadings : bodyDates),
              let day = printedDay(date.value) else { return nil }
        let time = unique(fragments(eventLines, source: source, pattern: #"\bat\s+("# + timePattern + #")\b"#))
        let referencePattern = #"\bCorrection to (?:my|the)\s+("# + referenceDatePattern + #")\s+message\s*[:.]"#
        let referenced = unique(fragments(lines, source: source, pattern: referencePattern))
        let correction = uniqueAnchors(fragments(lines, source: source,
            pattern: #"\b(Correction to (?:yesterday|my earlier message))\s*:"#).flatMap(\.evidence) +
            (referenced?.evidence ?? []))
        return Self(source: source.reference, scope: source.scope, person: person, title: title, eventDate: date, eventTime: time,
                    participation: status,
                    participationEvidence: uniqueAnchors(stated.values.flatMap { $0 }),
                    sentDate: sent, sender: sender, correction: correction, referencedSentDate: referenced, occurrenceDay: day,
                    sentDay: sent.flatMap { printedDay($0.value) })
    }

    public static func occurrenceTitle(inAdministrativeHeading text: String) -> String? {
        let prefixes = ["change to ", "update to ", "correction to "]
        if let prefix = prefixes.first(where: { text.lowercased().hasPrefix($0) }) {
            return String(text.dropFirst(prefix.count))
        }
        let suffixes = [" update", " correction"]
        guard let suffix = suffixes.first(where: { text.lowercased().hasSuffix($0) })
        else { return nil }
        let base = String(text.dropLast(suffix.count))
        return base.isEmpty ? nil : base
    }

    private static func unique(_ values: [PersonPlanText]) -> PersonPlanText? {
        let keys = Set(values.map { planKey($0.value) })
        guard keys.count == 1, let first = values.first else { return nil }
        return PersonPlanText(first.value, evidence: first.evidence)
    }

    private static let monthPattern = #"(?:January|February|March|April|May|June|July|August|September|October|November|December)"#
    private static let referenceDatePattern = #"(?:[0-9]{1,2}\s+"# + monthPattern + #"(?:\s+[0-9]{4})?|"# +
        monthPattern + #"\s+[0-9]{1,2}(?:,\s+[0-9]{4})?)"#
    private static let fullDatePattern = #"(?:[0-9]{1,2}\s+"# + monthPattern + #"\s+[0-9]{4}|"# +
        monthPattern + #"\s+[0-9]{1,2},\s+[0-9]{4})"#

    private static func currentMessageLines(_ lines: [SourceObservation]) -> [SourceObservation] {
        // Printed forward/reply boundaries end the current sender's authorship.
        // A second dated sender header also ends it, even without a banner.
        let boundary = try? NSRegularExpression(
            pattern: #"^(?:[-–— ]*(?:forwarded (?:reply|message)|original message)[-–— :]*|on .+ wrote:|>\s*.+)$"#,
            options: .caseInsensitive
        )
        let envelope = try? NSRegularExpression(
            pattern: #"^from\s+.+?\s+on\s+(?:"# + fullDatePattern + #")$"#, options: .caseInsensitive
        )
        var seenSender = false
        return Array(lines.prefix { line in
            let range = NSRange(line.value.startIndex..., in: line.value)
            if boundary?.firstMatch(in: line.value, range: range) != nil { return false }
            guard envelope?.firstMatch(in: line.value, range: range) != nil else { return true }
            if seenSender { return false }
            seenSender = true
            return true
        })
    }

    /// Compares local wall-clock values while preserving the exact printed text
    /// and deriving neither a date nor a timezone from a clock string.
    fileprivate static func meridiemMinutes(_ text: String) -> Int? {
        let parts = planKey(text).split(separator: " ")
        guard parts.count == 2, parts[1] == "am" || parts[1] == "pm" else { return nil }
        let clock = parts[0].split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(clock.count), let hour = Int(clock[0]), (1...12).contains(hour) else { return nil }
        let minute = clock.count == 1 ? 0 : Int(clock[1])
        guard let minute, (0...59).contains(minute) else { return nil }
        return ((hour % 12) + (parts[1] == "pm" ? 12 : 0)) * 60 + minute
    }

    fileprivate static func printedDay(_ text: String, referenceYear: Int? = nil) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for layout in ["d MMMM yyyy", "MMMM d, yyyy"] {
            formatter.dateFormat = layout
            if let date = formatter.date(from: text) { return date }
        }
        guard let referenceYear else { return nil }
        let dateFirst = text.first?.isNumber == true
        formatter.dateFormat = dateFirst ? "d MMMM yyyy" : "MMMM d, yyyy"
        return formatter.date(from: text + (dateFirst ? " " : ", ") + String(referenceYear))
    }

    private static func lineValues(_ lines: [SourceObservation], source: SourceSnapshot, pattern: String)
        -> [PersonPlanText] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return lines.compactMap { readFragment([$0], source: source, expression: expression) }
    }

    private static func fragments(_ lines: [SourceObservation], source: SourceSnapshot, pattern: String)
        -> [PersonPlanText] {
        // Retain only the minimum current adjacent span for each match.
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        var result: [PersonPlanText] = []
        for i in lines.indices {
            for length in 1...min(3, lines.count - i) {
                let window = Array(lines[i..<(i+length)])
                if let span = readFragment(window, source: source, expression: expression) {
                    if !result.contains(where: {
                        $0.value == span.value && Set($0.evidence.map(\.observationID))
                            .isSubset(of: Set(span.evidence.map(\.observationID)))
                    }) { result.append(span) }
                    break
                }
            }
        }
        return result
    }

    private static func readFragment(_ lines: [SourceObservation], source: SourceSnapshot,
                                     expression: NSRegularExpression) -> PersonPlanText? {
        let text = lines.map(\.value).joined(separator: " ")
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let span = Range(match.range(at: 1), in: text)
        else { return nil }
        let lower = match.range(at: 1).location
        let upper = lower + match.range(at: 1).length
        var offset = 0
        let anchors = lines.compactMap { line -> EvidenceAnchor? in
            let start = offset
            offset += line.value.utf16.count + 1
            guard start < upper && (offset - 1) > lower else { return nil }
            return EvidenceAnchor(source: source.reference, observationID: line.id, quote: line.value)
        }
        return PersonPlanText(String(text[span]), evidence: anchors)
    }
}

public struct CurrentPersonPlan: Sendable {
    public let initial: PersonPlanMessage
    public let amendment: PersonPlanMessage?
    public let competingUpdates: [PersonPlanMessage]
    public var participation: PersonPlanMessage.Participation {
        competingUpdates.isEmpty ? (amendment?.participation ?? initial.participation) : .unclear
    }
    public var currentEvidence: [EvidenceAnchor] {
        if !competingUpdates.isEmpty { return initial.participationEvidence + competingUpdates.flatMap(\.participationEvidence) }
        return amendment?.participationEvidence ?? initial.participationEvidence
    }
}

public enum PersonPlanMessageResolution {
    /// Resolves only exact title, person and printed day matches from a
    /// single explicitly dated sender correction against one predecessor.
    /// The previously displayed membership is always selected by original ID.
    public static func resolve(_ inputs: [PersonPlanMessage], scope: MemoryScope, currentSources: Set<SourceReference>,
                               restrictedTo displayed: Set<SourceReference>? = nil) -> [CurrentPersonPlan] {
        guard Set(currentSources.map(\.id)).count == currentSources.count else { return [] }
        let current = inputs.filter { $0.scope == scope && currentSources.contains($0.source) }
        guard Set(current.map(\.source)).count == current.count else { return [] }
        let origins = current.filter { $0.correction.isEmpty && $0.participation != .withdrawn }
        let corrections = current.filter { !$0.correction.isEmpty && $0.participation == .withdrawn }
        let candidates = corrections.map { change in
            (change, origins.filter { sameOccurrence($0, change) })
        }
        return origins.compactMap { original in
            guard displayed.map({ $0.contains(original.source) }) ?? true else { return nil }
            let matches = candidates.filter { $0.1.contains(original) }
            if let candidate = matches.first, matches.count == 1, candidate.1.count == 1,
               orderedCorrection(candidate.0, after: original) {
                return CurrentPersonPlan(initial: original, amendment: candidate.0, competingUpdates: [])
            }
            return CurrentPersonPlan(initial: original, amendment: nil, competingUpdates: matches.map { $0.0 })
        }
    }

    private static func sameOccurrence(_ lhs: PersonPlanMessage, _ rhs: PersonPlanMessage) -> Bool {
        guard planKey(lhs.person) == planKey(rhs.person),
              planKey(lhs.title.value) == planKey(rhs.title.value),
              lhs.occurrenceDay == rhs.occurrenceDay else { return false }
        if let left = lhs.eventTime?.value, let right = rhs.eventTime?.value {
            guard let minutes = PersonPlanMessage.meridiemMinutes(left) else { return false }
            return minutes == PersonPlanMessage.meridiemMinutes(right)
        }
        return true
    }

    private static func orderedCorrection(_ correction: PersonPlanMessage, after original: PersonPlanMessage) -> Bool {
        guard let sender = original.sender?.value, let correctedSender = correction.sender?.value,
              planKey(sender) == planKey(correctedSender),
              let sent = original.sentDay, let changed = correction.sentDay, changed > sent
        else { return false }
        if let explicitReference = correction.referencedSentDate?.value {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
            // An omitted reference year is scoped to this uniquely selected,
            // source-backed earlier message. It is never exposed as printed fact.
            let year = calendar.component(.year, from: sent)
            return PersonPlanMessage.printedDay(explicitReference, referenceYear: year) == sent
        }
        let yesterday = correction.correction.contains { $0.quote.lowercased().contains("correction to yesterday") }
        return !yesterday || abs(changed.timeIntervalSince(sent) - 86_400) < 0.01
    }
}

private func planKey(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.lowercased()
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func uniqueAnchors(_ values: [EvidenceAnchor]) -> [EvidenceAnchor] {
    var seen = Set<String>()
    return values.filter { seen.insert($0.observationID).inserted }
}

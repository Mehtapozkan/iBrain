import Foundation
import IBrain

public enum PersonPlanRole: String, Codable, Sendable {
    case included, conditional, organizerOnly, declined, mentioned, uncertain
}

public enum PersonPlanStatus: String, Codable, Sendable {
    case confirmed, tentative, cancelled, unclear
}

public struct PersonPlanText: Codable, Equatable, Sendable {
    public let value: String
    public let evidence: [EvidenceAnchor]

    public init(_ value: String, evidence: [EvidenceAnchor]) {
        self.value = value
        self.evidence = evidence
    }
}

public struct PersonPlanStatusEvidence: Codable, Equatable, Sendable {
    public let status: PersonPlanStatus
    public let support: PersonPlanText

    public init(_ status: PersonPlanStatus, support: PersonPlanText) {
        self.status = status
        self.support = support
    }
}

/// A provider proposal about one plan. Every field is bound to current source
/// observations before use. Citation validity and semantic entailment differ.
public struct PersonPlanProposal: Codable, Equatable, Sendable {
    public let person: PersonPlanText
    public let role: PersonPlanRole
    public let roleEvidence: [EvidenceAnchor]
    public let title: PersonPlanText
    public let printedDate: PersonPlanText?
    public let statusEvidence: [PersonPlanStatusEvidence]

    public init(person: PersonPlanText, role: PersonPlanRole, roleEvidence: [EvidenceAnchor],
                title: PersonPlanText, printedDate: PersonPlanText?,
                statusEvidence: [PersonPlanStatusEvidence]) {
        self.person = person
        self.role = role
        self.roleEvidence = roleEvidence
        self.title = title
        self.printedDate = printedDate
        self.statusEvidence = statusEvidence
    }
}

public struct PersonPlanEvidence: Equatable, Sendable {
    public static let version = "person-plan-evidence-v1.1"
    public let source: SourceReference
    public let proposal: PersonPlanProposal
    public let status: PersonPlanStatus
    public let title: PersonPlanText
    public let printedDate: PersonPlanText?
    public let admittedRoleEvidence: [EvidenceAnchor]
    public let admittedStatusEvidence: [PersonPlanStatusEvidence]

    /// Return nil for invalid evidence, a mismatched person, or when the source
    /// establishes a different role. Unresolved provider reads should remain
    /// represented in the host's coverage instead of counted as nonmatches.
    public static func admit(_ proposal: PersonPlanProposal, requestedPerson: String,
                             on source: SourceSnapshot) -> PersonPlanEvidence? {
        guard [.included, .conditional].contains(proposal.role),
              normalized(proposal.person.value) == normalized(requestedPerson),
              let matcher = try? NSRegularExpression(pattern:
                #"(?<![\p{L}\p{M}\p{N}'’\-])"# + NSRegularExpression.escapedPattern(for: proposal.person.value)
                + #"(?![\p{L}\p{M}\p{N}'’\-])"#, options: .caseInsensitive),
              (proposal.person.evidence + proposal.roleEvidence).contains(where: { anchor in
                matcher.firstMatch(in: anchor.quote,
                    range: NSRange(anchor.quote.startIndex..., in: anchor.quote)) != nil
              }),
              let personQuotes = checkedQuotes(proposal.person.evidence, on: source),
              personQuotes.allSatisfy({ quote in
                matcher.firstMatch(in: quote, range: NSRange(quote.startIndex..., in: quote)) != nil
              }),
              checkedQuotes(proposal.roleEvidence, on: source) != nil,
              supported(proposal.title, on: source),
              proposal.printedDate.map({ supported($0, on: source) }) ?? true,
              proposal.statusEvidence.allSatisfy({ supported($0.support, on: source) })
        else { return nil }
        // The provider may cite an accurate quote while misreading its role.
        // This bounded one-plan reader accepts explicit participation phrases.
        let person = NSRegularExpression.escapedPattern(for: proposal.person.value)
        let name = #"(?<![\p{L}\p{M}\p{N}'’\-])"# + person + #"(?![\p{L}\p{M}\p{N}'’\-])"#
        let participation = [
            name + #"\s+and\s+(?:I|we)\s+(?:(?:are|will be)\s+(?:going|attending|joining)|plan(?:ned)?\b)"#,
            #"\b(?:plan(?:ned)?|suggest(?:ed)?|book(?:ed)?|propos(?:e|ed))\b[^.!?]{0,120}\bwith\s+"# + name,
            name + #"\s+(?:(?:is|will be)\s+(?:going|attending|joining)|will\s+(?:attend|join)\b)"#
        ]
        let eligible = source.observations.filter { $0.kind == .text }
        let participantRows = eligible.filter { line in participation.contains { matches($0, in: line.value) } }
        guard participantRows.count == 1, let participantRow = participantRows.first,
              !eligible.contains(where: { matches(name + #"\s+(?:won['’]t|cannot|can['’]t|will not|declined|is not)\b"#, in: $0.value) })
        else { return nil }

        // Credit the source's explicit status cues. A proposed status that
        // contradicts a printed condition or conflict is not admitted.
        let rules: [(PersonPlanStatus, String)] = [
            (.cancelled, #"\b(?:cancelled|canceled|called off)\b"#),
            (.tentative, #"\b(?:tentative|not (?:yet )?confirmed|pending(?: a reply| confirmation)?|waiting for[^.!?]{0,45}repl(?:y|ies)|if (?:he|she|they|we|i) can (?:make it|come|attend))\b"#),
            (.confirmed, #"\b(?:confirmed|definitely happening)\b"#)
        ]
        let statusEvidence = eligible.flatMap { line in
            rules.compactMap { state, pattern -> PersonPlanStatusEvidence? in
                guard matches(pattern, in: line.value) else { return nil }
                if state == .confirmed && matches(#"\b(?:not (?:yet )?confirmed|unconfirmed|never confirmed)\b"#, in: line.value) {
                    return nil
                }
                return PersonPlanStatusEvidence(state, support: PersonPlanText(line.value, evidence: [anchor(line, source)]))
            }
        }
        let statuses = Set(statusEvidence.map(\.status))
        var status = statuses.count == 1 ? (statuses.first ?? .unclear) : .unclear
        if proposal.role == .conditional && status == .confirmed { status = .unclear }

        let datePattern = #"\b[0-9]{1,2}\s+(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+[0-9]{4}\b"#
        let date = proposal.printedDate.flatMap { field in
            matchedText(datePattern, in: field.value).map { PersonPlanText($0, evidence: field.evidence) }
        }
        var title = proposal.title
        if let date, let range = title.value.range(of: " on " + date.value, options: [.caseInsensitive]) {
            let prefix = String(title.value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { title = PersonPlanText(prefix, evidence: title.evidence) }
        }
        return PersonPlanEvidence(source: source.reference, proposal: proposal, status: status,
                                  title: title, printedDate: date, admittedRoleEvidence: [anchor(participantRow, source)],
                                  admittedStatusEvidence: statusEvidence)
    }

    private static func matches(_ pattern: String, in value: String) -> Bool {
        matchedText(pattern, in: value) != nil
    }

    private static func matchedText(_ pattern: String, in value: String) -> String? {
        guard let range = value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(value[range])
    }

    private static func anchor(_ line: SourceObservation, _ source: SourceSnapshot) -> EvidenceAnchor {
        EvidenceAnchor(source: source.reference, observationID: line.id, quote: line.value)
    }

    private static func supported(_ text: PersonPlanText, on source: SourceSnapshot) -> Bool {
        guard !text.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let quotes = checkedQuotes(text.evidence, on: source) else { return false }
        if quotes.contains(where: { $0.contains(text.value) }) { return true }
        let positions = text.evidence.compactMap { anchor in
            source.observations.firstIndex { $0.id == anchor.observationID }
        }
        return positions.count == text.evidence.count &&
            zip(positions, positions.dropFirst()).allSatisfy { $1 == $0 + 1 } &&
            quotes.joined(separator: " ").contains(text.value)
    }

    private static func checkedQuotes(_ anchors: [EvidenceAnchor], on source: SourceSnapshot) -> [String]? {
        guard !anchors.isEmpty else { return nil }
        for anchor in anchors {
            let matches = source.observations.filter { $0.id == anchor.observationID && $0.kind == .text }
            guard anchor.source == source.reference, matches.count == 1,
                  !anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  matches[0].value.contains(anchor.quote)
            else { return nil }
        }
        return anchors.map(\.quote)
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
}

import Foundation

public enum LabelledFieldValuePolicy: Sendable {
    case legacyWholeLines
    case explicitColonLabelsV1
    case labelledLocationBlocksV2
    case labelledVenueComponentsV3
}

/// A deterministic literal substring derivation after a semantic reader has
/// already selected this field's source. It grants no source or write authority.
public struct LabelledFieldValueDerivation: Codable, Equatable, Sendable {
    public let field: AppointmentField
    public let source: SourceReference
    public let observationID: String
    public let originalQuote: String
    public let valueQuote: String
    public let valueUTF8LowerBound: Int
    public let valueUTF8UpperBound: Int
}

public struct LabelledFieldValueResult: Codable, Equatable, Sendable {
    public let projection: MemoryProjection
    public let derivations: [LabelledFieldValueDerivation]
}

/// Optional pre-admission value projection for explicitly labelled venue and
/// venue-address text. Full OCR observations/regions remain untouched. Narrowed
/// quotes remain byte-exact source substrings; existing store/binding checks and
/// host CAS still apply. Never apply this to rewrite an admitted record in place.
public enum LabelledAppointmentFieldValues {
    public static let version = "labelled-appointment-values-v1"
    public static let versionV2 = "labelled-appointment-location-block-v2"
    public static let versionV3 = "labelled-appointment-venue-components-v3"

    public static func project(_ input: MemoryProjection, sources: [SourceSnapshot],
                               policy: LabelledFieldValuePolicy = .legacyWholeLines) throws -> LabelledFieldValueResult {
        guard policy != .legacyWholeLines else { return LabelledFieldValueResult(projection: input, derivations: []) }
        guard Set(sources.map { $0.reference.id }).count == sources.count else { throw MemoryError.invalidSnapshot }
        guard sources.allSatisfy({ Set($0.observations.map(\.id)).count == $0.observations.count }) else { throw MemoryError.invalidSnapshot }
        guard sources.allSatisfy({ $0.scope == input.scope }) else { throw MemoryError.scopeMismatch }
        guard Set(input.support.map(\.field)).count == input.support.count else { throw MemoryError.invalidEvidence }
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.reference.id, $0) })
        var support = input.support
        var venue = input.appointment.venue, address = input.appointment.venueAddress
        var derivations: [LabelledFieldValueDerivation] = []
        let venueProof=input.support.first{$0.field == .venue},addressProof=input.support.first{$0.field == .venueAddress}
        let sameSelectedBlock=venue != nil && venue==address && venueProof?.origin == .observed && addressProof?.origin == .observed && venueProof?.anchors.count==1 && venueProof?.anchors==addressProof?.anchors
        let locationBlocks=policy == .labelledLocationBlocksV2 || policy == .labelledVenueComponentsV3
        let derivationVersion=policy == .labelledVenueComponentsV3 ? versionV3:policy == .labelledLocationBlocksV2 ? versionV2:version
        for (field, value) in [(AppointmentField.venue, venue), (.venueAddress, address)] {
            guard let value else { continue }
            guard let index = support.firstIndex(where: { $0.field == field }) else { throw MemoryError.invalidEvidence }
            let proof = support[index]
            // Human/domain corrections and inferred values are never normalized
            // by a source-reading policy.
            guard proof.origin == .observed else { continue }
            guard !proof.anchors.isEmpty, proof.confidence.isFinite, (0...1).contains(proof.confidence),
                  !proof.extractorVersion.isEmpty, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MemoryError.invalidEvidence }
            var anchors: [EvidenceAnchor] = [], local: [LabelledFieldValueDerivation] = []
            for anchor in proof.anchors {
                guard let source = byID[anchor.source.id], source.reference == anchor.source,
                      let observation = source.observations.first(where: { $0.id == anchor.observationID }), observation.kind == .text,
                      !anchor.quote.isEmpty, Data(observation.value.utf8).range(of: Data(anchor.quote.utf8)) != nil else { throw MemoryError.invalidEvidence }
                if let range = try (locationBlocks && sameSelectedBlock ? locationBlockRange(in:anchor.quote,field:field):nil) ?? valueRange(in: anchor.quote, field: field) {
                    let text = String(anchor.quote[range])
                    anchors.append(EvidenceAnchor(source: anchor.source, observationID: anchor.observationID, quote: text))
                    local.append(LabelledFieldValueDerivation(field: field, source: anchor.source, observationID: anchor.observationID,
                        originalQuote: anchor.quote, valueQuote: text, valueUTF8LowerBound: anchor.quote[..<range.lowerBound].utf8.count,
                        valueUTF8UpperBound: anchor.quote[..<range.upperBound].utf8.count))
                } else { anchors.append(anchor) }
            }
            func unique(_ quotes: [String]) -> [String] {
                quotes.reduce(into: []) { result, quote in if !result.contains(quote) { result.append(quote) } }
            }
            let old = unique(proof.anchors.map(\.quote)), next = unique(anchors.map(\.quote))
            let nextValue: String
            if field == .venue && policy != .labelledVenueComponentsV3 {
                guard next.count == 1, old.contains(value) || value == next[0] else { throw MemoryError.invalidEvidence }
                nextValue = next[0]
            } else {
                nextValue = next.joined(separator: "\n")
                guard value == old.joined(separator: "\n") || value == nextValue else { throw MemoryError.invalidEvidence }
            }
            guard !local.isEmpty else { continue }
            let extractor = proof.extractorVersion.hasSuffix("/" + derivationVersion) ? proof.extractorVersion : proof.extractorVersion + "/" + derivationVersion
            support[index] = FieldSupport(field: field, origin: proof.origin, anchors: anchors,
                confidence: proof.confidence, extractorVersion: extractor)
            if field == .venue { venue = nextValue } else { address = nextValue }
            derivations.append(contentsOf: local)
        }
        guard !derivations.isEmpty else { return LabelledFieldValueResult(projection: input, derivations: []) }
        let a = input.appointment
        let appointment = AppointmentProjection(title: a.title, provider: a.provider, venue: venue, date: a.date,
            kind: a.kind, status: a.status, performer: a.performer, venueAddress: address)
        let output = MemoryProjection(recordID: input.recordID, recordRevision: input.recordRevision, scope: input.scope,
            appointment: appointment, support: support, documentOnlyWithoutDate: input.documentOnlyWithoutDate == true)
        guard output.sources == input.sources else { throw MemoryError.invalidEvidence }
        return LabelledFieldValueResult(projection: output, derivations: derivations)
    }

    /// A visibly labelled, newline-delimited place/name/street block selected
    /// by BOTH semantic roles. Never derive a missing role or use issuer labels.
    private static func locationBlockRange(in quote:String,field:AppointmentField)->Range<String.Index>? {
        guard let colon=quote.firstIndex(of:":"),["venue","location","veranstaltungsort"].contains(normalizedLabel(quote[..<colon]))else{return nil}
        let after=quote.index(after:colon)
        guard quote[after...].first=="\n" || quote[after...].hasPrefix("\r\n")else{return nil}
        let parts=quote[after...].split(whereSeparator: \.isNewline).compactMap{part->Range<String.Index>? in
            guard let first=part.firstIndex(where:{!$0.isWhitespace}),let last=part.lastIndex(where:{!$0.isWhitespace})else{return nil}
            return first..<quote.index(after:last)
        }
        guard (3...6).contains(parts.count),!quote[parts[0]].contains(":"),!quote[parts[1]].contains(":"),quote[parts[1]].range(of:#"\p{L}"#,options:.regularExpression) != nil,quote[parts[1]].range(of:#"[0-9]"#,options:.regularExpression) != nil else{return nil}
        // A postcode/locality alone does not establish a street address.
        if quote[parts[1]].range(of:#"^[0-9]{4,6}\s+\p{L}+(?:\s+\p{L}+)*$"#,options:.regularExpression) != nil {return nil}
        return field == .venue ? parts[0]:parts[1].lowerBound..<parts.last!.upperBound
    }

    private static func labels(for field: AppointmentField) -> Set<String> {
        if field == .venue { return ["venue", "location", "new venue", "current venue", "new location", "current location"] }
        return ["address", "venue address", "new address", "current address", "new venue address", "current venue address"]
    }
    private static func normalizedLabel(_ text: Substring) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func valueRange(in quote: String, field: AppointmentField) throws -> Range<String.Index>? {
        guard let colon = quote.firstIndex(of: ":"), labels(for: field).contains(normalizedLabel(quote[..<colon])) else { return nil }
        let after = quote.index(after: colon), tail = quote[after...]
        guard let start = tail.firstIndex(where: { !$0.isWhitespace }), let end = tail.lastIndex(where: { !$0.isWhitespace }) else { throw MemoryError.invalidEvidence }
        let range = start..<quote.index(after: end), body = quote[range]
        // Repeated label syntax is ambiguous; do not recursively shave a name.
        if let nested = body.firstIndex(of: ":"), labels(for: field).contains(normalizedLabel(body[..<nested])) { throw MemoryError.invalidEvidence }
        return range
    }
}

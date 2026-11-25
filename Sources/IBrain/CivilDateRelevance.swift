import Foundation

/// Relevance to a requested window is separate from resolving an exact instant.
/// An `inside` result with an uncertainty issue is still a partial fact and
/// supplies no timezone, exact UTC timestamp or permission for a reminder.
public enum DateWindowMembership: String, Codable, Sendable {
    case inside, outside, unresolved
}
public enum DateRelevanceBasis: String, Codable, Sendable {
    case exactInstant, knownZoneDay, boundedUnknownZone, unfiltered, unresolved
}
public struct DateRelevance: Equatable, Sendable {
    public let membership: DateWindowMembership
    public let basis: DateRelevanceBasis
    public let unresolvedIssue: DateIssue?
    public let exactInstant: Date?
}
public enum PartialDatePolicy: String, Codable, Sendable {
    /// Preserve the strict exact-instant behavior.
    case strictInstant
    /// Explicit host policy for modern civil dates (1970 onward). Unknown
    /// zones retain every offset in [-14h,+14h], never a chosen device zone.
    /// Boundary overlaps remain unresolved. Earlier dates stay unresolved.
    case modernWorldwideOffsetEnvelopeV1
}
public enum NativeDateRelevance {
    private struct Bounds {
        let lower: Date
        let upper: Date
        let upperInclusive: Bool
    }
    private static func result(_ membership: DateWindowMembership,
                               _ basis: DateRelevanceBasis,
                               _ issue: DateIssue? = nil, instant: Date? = nil) -> DateRelevance {
        DateRelevance(membership: membership, basis: basis,
                      unresolvedIssue: issue, exactInstant: instant)
    }
    private static func classify(_ bounds: Bounds, interval: DateInterval,
                                 basis: DateRelevanceBasis, issue: DateIssue) -> DateRelevance {
        let endsBefore = bounds.upperInclusive ? bounds.upper < interval.start : bounds.upper <= interval.start
        if endsBefore || bounds.lower >= interval.end { return result(.outside, basis, issue) }
        let endsInside = bounds.upperInclusive ? bounds.upper < interval.end : bounds.upper <= interval.end
        if bounds.lower >= interval.start && endsInside { return result(.inside, basis, issue) }
        return result(.unresolved, basis, issue)
    }
    public static func assess(_ value: EventDate, window: QueryWindow,
                              partialPolicy: PartialDatePolicy = .strictInstant,
                              inferredPolicy: InferredDatePolicy = .explicitOnly) -> DateRelevance {
        let resolution = NativeDates.resolve(value, inferredPolicy: inferredPolicy)
        if case .instant(let instant) = resolution {
            return result(window.contains(instant) ? .inside : .outside, .exactInstant, instant: instant)
        }
        guard case .uncertain(let issue) = resolution else { return result(.unresolved, .unresolved) }
        if case .all = window { return result(.inside, .unfiltered, issue) }
        guard partialPolicy == .modernWorldwideOffsetEnvelopeV1,
              case .interval(let interval) = window else { return result(.unresolved, .unresolved, issue) }
        guard value.certainty != .conflicting else { return result(.unresolved, .unresolved, .conflicting) }
        if value.certainty == .inferred && !(TemporalResolution.allowsFiltering(value,policy:inferredPolicy)) {
            return result(.unresolved, .unresolved, .inferred)
        }
        guard let year = value.year else { return result(.unresolved, .unresolved, .missingYear) }
        guard let month = value.month, let day = value.day else { return result(.unresolved, .unresolved, .missingDate) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayParts = DateComponents(year: year, month: month, day: day)
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let civilStart = utc.date(from: dayParts),
              utc.dateComponents([.year,.month,.day], from: civilStart) == dayParts else {
            return result(.unresolved, .unresolved, .invalidDate)
        }
        if let hour = value.hour, !(0...23).contains(hour) { return result(.unresolved, .unresolved, .invalidDate) }
        if let minute = value.minute, !(0...59).contains(minute) { return result(.unresolved, .unresolved, .invalidDate) }

        // A known zone and missing clock form that real calendar day's interval,
        // including DST length. A complete but invalid/ambiguous clock is never
        // widened into a successful partial match.
        if let id = value.timeZoneID, let zone = TimeZone(identifier: id) {
            guard value.hour == nil || value.minute == nil,
                  value.utcOffsetSeconds == nil else { return result(.unresolved, .unresolved, issue) }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            guard let start = calendar.date(from: dayParts),
                  calendar.dateComponents([.year,.month,.day], from: start) == dayParts,
                  let range = calendar.dateInterval(of: .day, for: start) else {
                return result(.unresolved, .unresolved, .invalidDate)
            }
            return classify(Bounds(lower:range.start,upper:range.end,upperInclusive:false),
                            interval:interval,basis:.knownZoneDay,issue:issue)
        }
        // An explicitly unresolved zone/offset is not an absent-zone policy.
        guard value.timeZoneID == nil, value.utcOffsetSeconds == nil else {
            return result(.unresolved, .unresolved, issue)
        }
        guard year >= 1970 else { return result(.unresolved, .unresolved, issue) }
        let offsetEnvelope: TimeInterval = 14 * 60 * 60
        if let hour = value.hour, let minute = value.minute,
           let civilClock = utc.date(byAdding:.minute,value:hour*60+minute,to:civilStart) {
            return classify(Bounds(lower:civilClock.addingTimeInterval(-offsetEnvelope),
                                   upper:civilClock.addingTimeInterval(offsetEnvelope),upperInclusive:true),
                            interval:interval,basis:.boundedUnknownZone,issue:issue)
        }
        guard let nextDay = utc.date(byAdding:.day,value:1,to:civilStart) else {
            return result(.unresolved,.unresolved,.invalidDate)
        }
        return classify(Bounds(lower:civilStart.addingTimeInterval(-offsetEnvelope),
                               upper:nextDay.addingTimeInterval(offsetEnvelope),upperInclusive:false),
                        interval:interval,basis:.boundedUnknownZone,issue:issue)
    }
}

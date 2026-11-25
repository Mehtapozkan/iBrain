import Foundation

public enum QueryPeriod: String, Codable, Sendable { case all, today, tomorrow, thisWeek, nextWeek, nextSevenDays, inherit, unsupported }
public enum QueryOperation: String, Codable, Sendable { case appointments, location, literalSourceText, unsupported, unclear }
public enum QuerySelection: String, Codable, Sendable { case all, eventTickets, unsupported }

/// No model-produced dates, memory IDs, permissions, or effects.
public struct QueryMeaning: Codable, Equatable, Sendable {
    public let operation: QueryOperation
    public let period: QueryPeriod
    public let selection: QuerySelection
    public let ordinal: Int?
    public init(operation: QueryOperation, period: QueryPeriod, selection: QuerySelection = .all, ordinal: Int? = nil) {
        self.operation = operation; self.period = period; self.selection = selection; self.ordinal = ordinal
    }
}

public struct InterpretationRequest: Sendable {
    public let question: String
    public let now: Date
    public let calendar: Calendar
    public let previous: ConversationSummary?
    public init(question: String, now: Date, calendar: Calendar, previous: ConversationSummary? = nil) {
        self.question = question; self.now = now; self.calendar = calendar; self.previous = previous
    }
}
public struct ConversationSummary: Codable, Sendable {
    public let period: QueryPeriod
    public let orderedTitles: [String]
    /// Present only for an explicitly bound mixed list. An uncertain item is
    /// referenceable without claiming it has a resolved calendar instant.
    public let orderedDateIssues: [DateIssue?]?
    public init(period: QueryPeriod, orderedTitles: [String], orderedDateIssues: [DateIssue?]? = nil) {
        self.period = period; self.orderedTitles = orderedTitles; self.orderedDateIssues = orderedDateIssues
    }
}
public protocol QueryInterpreter: Sendable {
    func interpret(_ request: InterpretationRequest) async throws -> QueryMeaning
}

public enum DateIssue: String, Codable, Sendable {
    case missingYear, missingDate, missingTime, unknownTimeZone, inferred, conflicting
    case invalidDate, nonexistentLocalTime, ambiguousLocalTime, conflictingOffset
}
public enum EventDateResolution: Equatable, Sendable { case instant(Date), uncertain(DateIssue) }

public enum NativeDates {
    /// Event dates use a strict Gregorian calendar and an explicit IANA zone.
    /// Gaps are rejected; repeated times need an explicit matching UTC offset.
    public static func resolve(_ value: EventDate, inferredPolicy: InferredDatePolicy = .explicitOnly) -> EventDateResolution {
        guard value.certainty != .conflicting else { return .uncertain(.conflicting) }
        guard let month = value.month, let day = value.day else { return .uncertain(.missingDate) }
        guard let year = value.year else { return .uncertain(.missingYear) }
        guard let hour = value.hour, let minute = value.minute else { return .uncertain(.missingTime) }
        guard let zoneID = value.timeZoneID, let zone = TimeZone(identifier: zoneID) else { return .uncertain(.unknownTimeZone) }
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute) else { return .uncertain(.invalidDate) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let dayComponents = DateComponents(year: year, month: month, day: day)
        guard let start = calendar.date(from: dayComponents),
              calendar.dateComponents([.year, .month, .day], from: start) == dayComponents else { return .uncertain(.invalidDate) }
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0)
        let first = calendar.nextDate(after: start.addingTimeInterval(-1), matching: components, matchingPolicy: .strict, repeatedTimePolicy: .first)
        let last = calendar.nextDate(after: start.addingTimeInterval(-1), matching: components, matchingPolicy: .strict, repeatedTimePolicy: .last)
        guard let first, let last else { return .uncertain(.nonexistentLocalTime) }
        let date: Date
        if let offset = value.utcOffsetSeconds {
            guard let matching = [first, last].first(where: { zone.secondsFromGMT(for: $0) == offset }) else { return .uncertain(.conflictingOffset) }
            date = matching
        } else {
            guard first == last else { return .uncertain(.ambiguousLocalTime) }; date = first
        }
        if value.certainty == .inferred && !(TemporalResolution.allowsFiltering(value,policy:inferredPolicy)) { return .uncertain(.inferred) }
        return .instant(date)
    }

    public static func window(_ period: QueryPeriod, now: Date, calendar: Calendar) throws -> QueryWindow {
        let interval: DateInterval?
        switch period {
        case .all: return .all
        case .today: interval = calendar.dateInterval(of: .day, for: now)
        case .tomorrow:
            interval = calendar.date(byAdding: .day, value: 1, to: now).flatMap { calendar.dateInterval(of: .day, for: $0) }
        case .thisWeek: interval = calendar.dateInterval(of: .weekOfYear, for: now)
        case .nextWeek:
            interval = calendar.dateInterval(of: .weekOfYear, for: now).flatMap { calendar.dateInterval(of: .weekOfYear, for: $0.end) }
        case .nextSevenDays:
            interval = calendar.date(byAdding: .day, value: 7, to: now).map { DateInterval(start: now, end: $0) }
        case .inherit, .unsupported: throw MemoryError.unsupportedQuery
        }
        guard let interval else { throw MemoryError.unsupportedQuery }
        return .interval(interval)
    }
}

public enum QueryWindow: Equatable, Sendable {
    case all, interval(DateInterval)
    public func contains(_ date: Date) -> Bool {
        switch self { case .all: true; case .interval(let i): date >= i.start && date < i.end }
    }
}
public struct RecallQuery: Equatable, Sendable {
    public let period: QueryPeriod
    public let selection: QuerySelection
    public let inferredDatePolicy: InferredDatePolicy
    public init(period: QueryPeriod, selection: QuerySelection = .all, inferredDatePolicy: InferredDatePolicy = .explicitOnly) {
        self.period = period; self.selection = selection; self.inferredDatePolicy = inferredDatePolicy
    }
}
public enum QueryPlan: Equatable, Sendable {
    case recall(RecallQuery), refine(selection: QuerySelection), location(ordinal: Int), literalSourceText, unresolved, unsupported
}
public enum QueryCompiler {
    public static func compile(_ meaning: QueryMeaning, previous: ConversationSummary? = nil) -> QueryPlan {
        switch meaning.operation {
        case .appointments:
            guard meaning.ordinal == nil, meaning.selection != .unsupported, meaning.period != .unsupported else { return .unsupported }
            if meaning.period == .inherit {
                guard let previous, previous.period != .inherit, previous.period != .unsupported else { return .unresolved }
                return .refine(selection: meaning.selection)
            }
            return .recall(RecallQuery(period: meaning.period, selection: meaning.selection))
        case .location:
            guard meaning.period == .inherit, meaning.selection == .all,
                  let ordinal = meaning.ordinal, ordinal > 0, let previous, ordinal <= previous.orderedTitles.count else { return .unresolved }
            return .location(ordinal: ordinal)
        case .literalSourceText: return .literalSourceText
        case .unclear: return .unresolved
        case .unsupported: return .unsupported
        }
    }
}

public enum RecallCoverage: String, Sendable { case incomplete, unknown, currentAccessibleSources }
public struct DatedMatch: Equatable, Sendable {
    public let memory: StoredMemory
    public let date: Date
    public var originalSources: Set<SourceReference> { memory.projection.sources }
}
public struct UncertainMatch: Equatable, Sendable {
    public let memory: StoredMemory
    public let reason: DateIssue
}

/// Prepared answers are provisional until `admit`. Keep opaque receipts with
/// results, including empty results (which can become stale after an upsert).
public struct PreparedAnswer: Sendable {
    public let requestID: UUID
    public let matches: [DatedMatch]
    public let uncertain: [UncertainMatch]
    public let window: QueryWindow
    public let coverage: RecallCoverage
    public var canAssertPersonalCalendarIsEmpty: Bool { false }
    internal let permit: SnapshotPermit
    internal let query: RecallQuery
    internal let submittedAt: Date
    internal let calendar: Calendar
}

/// A process-local reference list, separate from persistent memory. It cannot
/// be decoded from old storage or silently renumbered after invalidation.
public struct ResultContext: Sendable {
    public let answerID: UUID
    public let summary: ConversationSummary
    internal let prepared: PreparedAnswer
    internal let ordered: [StoredMemory]
    internal let limitsToDisplayed: Bool
}
public struct LocationAnswer: Sendable {
    public let recordID: String
    public let venue: String?
    public let originalSources: Set<SourceReference>
}

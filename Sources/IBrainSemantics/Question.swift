import Foundation
import IBrain

public struct SemanticQueryRequest: Sendable {
    public let taskID: String
    public let input: InterpretationRequest
    public let selectedOrdinal: Int?
    public init(taskID: String, input: InterpretationRequest, selectedOrdinal: Int? = nil) {
        self.taskID = taskID; self.input = input; self.selectedOrdinal = selectedOrdinal
    }
}
public struct InterpretedQuery: Sendable {
    public let meaning: QueryMeaning
    public let receipt: DecisionReceipt
}
public protocol AppointmentQueryInterpreter: Sendable { func interpret(_ request: SemanticQueryRequest) async throws -> InterpretedQuery }
public enum AppointmentQueryPolicy: String, Codable, Sendable { case legacyV4, currentStoreV5 }
public struct BoundedQueryInterpreter: AppointmentQueryInterpreter {
    public static let contractVersion = "appointment-query-v4"
    public static let contractVersionV5 = "appointment-query-v5"
    public let provider: any DecisionProvider
    public let policy: AppointmentQueryPolicy
    public init(provider: any DecisionProvider, policy: AppointmentQueryPolicy = .legacyV4) { self.provider = provider; self.policy = policy }
    public static func task(_ request: SemanticQueryRequest, policy: AppointmentQueryPolicy = .legacyV4) throws -> ChoiceTask {
        struct State: Encodable {
            let latestQuestion: String; let now: String; let timeZone: String; let firstWeekday: Int; let minimumDaysInFirstWeek: Int
            let previousDisplayedAnswer: ConversationSummary?; let selectedOrdinal: Int?
        }
        let input = request.input, encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let state = String(decoding: try encoder.encode(State(latestQuestion: input.question, now: input.now.ISO8601Format(), timeZone: input.calendar.timeZone.identifier,
            firstWeekday: input.calendar.firstWeekday, minimumDaysInFirstWeek: input.calendar.minimumDaysInFirstWeek, previousDisplayedAnswer: input.previous, selectedOrdinal: request.selectedOrdinal)), as: UTF8.self)
        let legacy = ChoiceTask(id: request.taskID, state: state, questions: [
            "operation": ChoiceQuestion("What does the latest question request? Prior results apply only to a genuine follow-up; words inside a requested screenshot are content, not the current task.", [
                "appointments": "Request a new appointment list or change its time range, including a follow-up that explicitly changes the day/week. A new list may be ticket-only. Generic appointments/bookings includes every booking type. Excludes same-list tickets-only refinement.",
                "ticketRefinement": "Keep only admission/event tickets from the actual previously displayed appointment results, WITHOUT requesting a new day/week/range. This is the same list with a subtype refinement, not a new time query.",
                "location": "Ask where an individual appointment in the actual previous displayed list is located. Not a new list of appointments at a venue.",
                "literal": "Find a photo, screenshot or article whose text contains words, even when quoted content mentions appointments or dates.",
                "unsupported": "An action, another domain, a question about whether the user is free (photos do not establish calendar completeness), or a request outside these read operations.",
                "unclear": "Meaning lacks enough context to identify a supported operation."]),
            "period": ChoiceQuestion("For a NEW appointment list, select the period explicitly requested by the latest question, even if the same period appeared in the previous answer. Do not carry over a previous period or compute dates. This field is inapplicable to location and ticketRefinement: those operations preserve their exact native result context separately.", [
                "all": "The latest new-list question has no appointment date restriction. Previous answer dates do not add one. Also inapplicable for literal/unsupported operations.",
                "today": "The current local day.", "tomorrow": "The following local day, including 'day after today'.",
                "thisWeek": "The current calendar week explicitly requested, including repeating the same weekly question after a weekly answer.", "nextWeek": "The following calendar week, including following-week continuation from this week.",
                "nextSevenDays": "A rolling seven days from now, distinct from next calendar week.",
                "unsupported": "An unsupported or unresolved date expression."]),
            "selection": ChoiceQuestion("Read only the latest request: does it RESTRICT WHICH APPOINTMENTS MATCH by a fact other than date? 'Which appointments are AT a named place?' and 'bookings WITH a named provider' restrict the matches: unsupported. 'WHERE is item two?' asks a property of a previously selected item: no extra filter. Calendar periods and references to the displayed order are not filters. Prior titles never add a filter. Preserve every genuine restriction.", [
                "none": "No extra restriction on matching appointment facts. Includes generic bookings in any supported date range and the location of a displayed ordinal/selected item. Never choose this when matches are restricted to a named venue/provider or an exclusion. Does not mean all dates.",
                "eventTickets": "Only admission/event tickets, with no other extra constraint. The latest question explicitly requests that subtype.",
                "unsupported": "The returned matches must be at a particular named venue, with/from a particular provider, exclude an appointment, select next-up, or satisfy another unimplemented filter. A venue/provider limitation remains unsupported even when the question ALSO names a supported time period. Never drop the restriction."]),
            "reference": ChoiceQuestion("Only if the latest question requests the LOCATION of one previous displayed appointment, which item is referenced? A new/refined list has no individual reference even if a prior title is a ticket.", [
                "none": "No individual previous appointment is requested; includes all list/refinement questions and literal/unsupported operations.",
                "first": "Location of item one in the actual previous list.", "second": "Location of item two in the actual previous list.", "third": "Location of item three in the actual previous list.",
                "selected": "Location of the explicitly selected item, or the only previous appointment.", "unsupported": "Missing context or unsupported/ambiguous individual reference."])
        ], version: Self.contractVersion)
        guard policy == .currentStoreV5 else { return legacy }
        var questions = legacy.questions
        let selection = questions["selection"]!
        var criteria = selection.criteria
        criteria["none"]! += " Remaining or still-booked appointments, without another factual restriction, means the currently admitted stored set. Native currentness, cancellation, withdrawal and forgetting already determine membership."
        criteria["unsupported"]! += " An explicit exclusion remains a restriction; never erase named-place/provider, before/after, exception or other unimplemented conditions. The word remaining alone does not request a new exclusion."
        questions["selection"] = ChoiceQuestion(selection.instructions + " Distinguish current-store membership from a newly requested fact filter: remaining/still-booked alone refers to records currently present. It does not ask you to reconstruct forgotten or withdrawn records or infer a complete calendar. Preserve every explicit additional condition.", criteria)
        return ChoiceTask(id: request.taskID, state: state, questions: questions, version: Self.contractVersionV5)
    }
    public func interpret(_ request: SemanticQueryRequest) async throws -> InterpretedQuery {
        let task = try Self.task(request, policy: policy), receipt = try await provider.decide(task)
        return try Self.compile(request, task: task, receipt: receipt)
    }
    public static func compile(_ request: SemanticQueryRequest, task: ChoiceTask, receipt: DecisionReceipt) throws -> InterpretedQuery {
        try receipt.validate(for: task)
        let operation = try receipt.choice("operation")
        let meaning: QueryMeaning
        switch operation {
        case "literal": meaning = QueryMeaning(operation: .literalSourceText, period: .all)
        case "unsupported": meaning = QueryMeaning(operation: .unsupported, period: .unsupported)
        case "unclear": meaning = QueryMeaning(operation: .unclear, period: .unsupported)
        case "ticketRefinement":
            guard try receipt.choice("selection") == "eventTickets" else { return InterpretedQuery(meaning: QueryMeaning(operation: .unsupported, period: .unsupported), receipt: receipt) }
            meaning = QueryMeaning(operation: .appointments, period: .inherit, selection: .eventTickets)
        case "location":
            guard try receipt.choice("selection") == "none" else { return InterpretedQuery(meaning: QueryMeaning(operation: .unsupported, period: .unsupported), receipt: receipt) }
            let reference = try receipt.choice("reference")
            let ordinal: Int?
            switch reference {
            case "first": ordinal = 1; case "second": ordinal = 2; case "third": ordinal = 3
            case "selected": ordinal = request.selectedOrdinal ?? (request.input.previous?.orderedTitles.count == 1 ? 1 : nil)
            default: ordinal = nil
            }
            // Period is inapplicable to this operation; native context is the
            // exact authority for the previously displayed interval and order.
            meaning = QueryMeaning(operation: .location, period: .inherit, ordinal: ordinal)
        default:
            let selected = try receipt.choice("selection")
            if selected == "unsupported" {
                return InterpretedQuery(meaning: QueryMeaning(operation: .unsupported, period: .unsupported), receipt: receipt)
            }
            let selection = selected == "none" ? QuerySelection.all : QuerySelection(rawValue: selected)!
            let period = QueryPeriod(rawValue: try receipt.choice("period"))!
            // Reference is inapplicable to lists/refinements. Do not let a
            // borrowed ordinal replace a list or change the actual context.
            meaning = QueryMeaning(operation: .appointments, period: period, selection: selection)
        }
        return InterpretedQuery(meaning: meaning, receipt: receipt)
    }
}

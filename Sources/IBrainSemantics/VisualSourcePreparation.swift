import IBrain

public enum SourcePreparationState: String, Sendable {
    case candidate, insufficientEvidence, groupingRequired
}
public enum SourcePreparationRequirement: String, Sendable {
    case documentMeaning, title, confirmation, kind, status
}

/// A validated reading outcome, not canonical admission or permission to read
/// another image. Persist the source request and raw receipt, then reassess.
public struct VisualSourcePreparationAssessment: Sendable {
    public let state: SourcePreparationState
    public let candidate: AppointmentCandidate?
    public let missingRequirements: [SourcePreparationRequirement]
    public let receipt: DecisionReceipt
    private let sourceAtRead: SourceSnapshot

    fileprivate init(state: SourcePreparationState, candidate: AppointmentCandidate? = nil,
                     missing: [SourcePreparationRequirement] = [], receipt: DecisionReceipt,
                     source: SourceSnapshot) {
        self.state = state; self.candidate = candidate; self.missingRequirements = missing
        self.receipt = receipt; sourceAtRead = source
    }
    /// Includes scope and all observations, even if a caller retained an old
    /// revision by mistake. Native access and current read authority are separate.
    public func validate(source: SourceSnapshot) throws {
        guard source == sourceAtRead else { throw SemanticError.invalidReceipt }
    }
}

public enum VisualSourcePreparationInterpreter {
    public static let version = "visual-source-preparation-assessment-v1"

    /// No alternate prompt or model call. Only explicitly opted-in V8 source
    /// readings are classified. Existing compile remains strict and unchanged.
    public static func assess(_ request: ObservationRequest, task: ChoiceTask,
                              receipt: DecisionReceipt) throws -> VisualSourcePreparationAssessment {
        guard request.documentPolicy == .documentContentV4,
              (request.temporalPolicy == .anchoredSpansV8 || request.temporalPolicy == .anchoredSpansV9) else { throw SemanticError.unsupportedEvidence }
        let expected = try VisualObservationInterpreter.task(request, detailPolicy: .componentsV4)
        guard task.id == expected.id, task.version == expected.version,
              try task.digest() == expected.digest() else { throw SemanticError.invalidReceipt }
        try receipt.validate(for: expected)
        return try assessValidated(request, task: task, receipt: receipt, choices: receipt)
    }
    /// The raw receipt is for the compact native task, never a synthetic legacy response.
    public static func assessCompact(_ request: ObservationRequest, task: ChoiceTask,
                                     receipt: DecisionReceipt) throws -> VisualSourcePreparationAssessment {
        guard request.documentPolicy == .documentContentV4,
              (request.temporalPolicy == .anchoredSpansV8 || request.temporalPolicy == .anchoredSpansV9) else { throw SemanticError.unsupportedEvidence }
        let prepared = try CompactQuestionKeys.prepare(VisualObservationInterpreter.task(request, detailPolicy: .componentsV4))
        let choices = try prepared.choices(task: task, receipt: receipt)
        return try assessValidated(request, task: task, receipt: receipt, choices: choices)
    }
    internal static func assessValidated(_ request: ObservationRequest, task: ChoiceTask,
        receipt: DecisionReceipt, choices: any DecisionChoiceReading) throws -> VisualSourcePreparationAssessment {
        func choice(_ key: String) throws -> String? {
            do { return try choices.choice(key) }
            catch SemanticError.lowConfidence { return nil }
        }
        func result(_ state: SourcePreparationState, missing: [SourcePreparationRequirement] = [],
                    candidate: AppointmentCandidate? = nil) -> VisualSourcePreparationAssessment {
            VisualSourcePreparationAssessment(state: state, candidate: candidate,
                missing: missing, receipt: receipt, source: request.source)
        }
        let document = try choice("document")
        // An uncertain grouping must not be flattened into one recovered record.
        // Not-booking remains the existing non-admitting candidate, irrespective
        // of how many advertisements or sample documents are pictured.
        if document != DocumentDisposition.notBooking.rawValue {
            guard try choice("documentCount") == "one",
                  request.visualGroupScope != nil || !request.source.observations.contains(where: {
                      $0.kind == .visualLabel && $0.value == "reader-reports-multiple-documents"
                  }) else { return result(.groupingRequired) }
        }
        if document == nil || document == DocumentDisposition.unclear.rawValue {
            return result(.insufficientEvidence, missing: [.documentMeaning])
        }
        if document == DocumentDisposition.booking.rawValue {
            var missing: [SourcePreparationRequirement] = []
            let title = try choice("title")
            if !request.lines.contains(where: { $0.id == title }) { missing.append(.title) }
            let confirmation = try choice("confirmation")
            if !request.source.observations.contains(where: { $0.id == confirmation }) { missing.append(.confirmation) }
            if try choice("kind").flatMap(AppointmentKind.init(rawValue:)) == nil { missing.append(.kind) }
            if try choice("status").flatMap(AppointmentStatus.init(rawValue:)) == nil { missing.append(.status) }
            if !missing.isEmpty { return result(.insufficientEvidence, missing: missing) }
        }
        // All other compilation errors remain errors. Do not infer recoverability
        // from exception strings or disguise transport/receipt failures as gaps.
        let candidate = try VisualObservationInterpreter.compileValidated(request, task: task,
            receipt: receipt, choices: choices, detailPolicy: .componentsV4)
        return result(.candidate, candidate: candidate)
    }
}

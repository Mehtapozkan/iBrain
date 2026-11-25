import Foundation

/// A new native task contract, not a transport-only rewrite. Every original
/// question and choice remains. Only output question keys become short aliases.
/// The actual receipt belongs to this task and is never rebound to its parent.
public struct CompactQuestionKeys: Sendable {
    public static let version = "native-compact-question-keys-v1"
    public let task: ChoiceTask
    private let original: ChoiceTask
    private let aliases: [String: String]

    public static func prepare(_ original: ChoiceTask) throws -> Self {
        guard !original.questions.isEmpty, original.questions.count <= 4096,
              original.version != version,
              original.questions.allSatisfy({ !$0.key.isEmpty && $0.value.type == "choice" && !$0.value.criteria.isEmpty }),
              try canonical(original).count <= 1_048_576 else { throw SemanticError.unsupportedEvidence }
        var questions: [String: ChoiceQuestion] = [:]
        var nativeKeys: [String: String] = [:]
        var aliases: [String: String] = [:]
        for (index, key) in original.questions.keys.sorted().enumerated() {
            let alias = "q\(index)", question = original.questions[key]!
            aliases[key] = alias
            nativeKeys[alias] = key
            questions[alias] = ChoiceQuestion(
                "This output key is a native alias. Resolve its semantic question key through questionKeys in the task state before following instructions that refer to the question's key. Source evidence is in sourceTask.state. Keep the original choice values unchanged. " + question.instructions,
                question.criteria)
        }
        struct SourceTask: Encodable {
            let id: String; let version: String; let requestSHA256: String
            let canonicalSHA256: String; let state: String
        }
        struct State: Encodable {
            let contract: String; let sourceTask: SourceTask; let questionKeys: [String: String]
        }
        let state = State(contract: version, sourceTask: SourceTask(id: original.id,
            version: original.version, requestSHA256: try original.digest(),
            canonicalSHA256: ChoiceTask.hash(try canonical(original)), state: original.state), questionKeys: nativeKeys)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let task = ChoiceTask(id: original.id, state: String(decoding: try encoder.encode(state), as: UTF8.self),
            questions: questions, version: version)
        guard try canonical(task).count <= 1_048_576 else { throw SemanticError.unsupportedEvidence }
        return Self(task: task, original: original, aliases: aliases)
    }

    internal func choices(task supplied: ChoiceTask, receipt: DecisionReceipt) throws -> CompactQuestionChoiceView {
        guard try Self.canonical(supplied) == Self.canonical(task) else { throw SemanticError.invalidReceipt }
        try receipt.validate(for: task)
        return CompactQuestionChoiceView(receipt: receipt, aliases: aliases)
    }

    internal static func canonical(_ task: ChoiceTask) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(task)
    }
}

/// Reads native meanings directly from the original compact-task receipt. The
/// validated alias map is regenerated from current source authority, not supplied
/// by the provider. Low-confidence errors retain the semantic key for callers.
internal struct CompactQuestionChoiceView: DecisionChoiceReading {
    let receipt: DecisionReceipt
    let aliases: [String: String]
    func choice(_ key: String) throws -> String {
        guard let alias = aliases[key] else { throw SemanticError.invalidReceipt }
        do { return try receipt.choice(alias) }
        catch SemanticError.lowConfidence { throw SemanticError.lowConfidence(key) }
    }
}

import Foundation
import CryptoKit
import IBrain

public enum SemanticError: Error, Equatable {
    case unavailable, invalidReceipt, lowConfidence(String), unsupportedEvidence, unresolved(String), existingAttempt
}
public struct ChoiceQuestion: Codable, Sendable {
    public let type: String
    public let instructions: String
    public let criteria: [String: String]
    public init(_ instructions: String, _ criteria: [String: String]) { self.type = "choice"; self.instructions = instructions; self.criteria = criteria }
}
public struct ChoiceTask: Codable, Sendable {
    public static let contractVersion = "appointment-semantics-v2"
    public let id: String
    public let version: String
    public let state: String
    public let questions: [String: ChoiceQuestion]
    public init(id: String, state: String, questions: [String: ChoiceQuestion], version: String = ChoiceTask.contractVersion) {
        self.id = id; self.state = state; self.questions = questions; self.version = version
    }
    private enum CodingKeys: String, CodingKey { case id, version, state, questions }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        version = try values.decodeIfPresent(String.self, forKey: .version) ?? Self.contractVersion
        state = try values.decode(String.self, forKey: .state)
        questions = try values.decode([String: ChoiceQuestion].self, forKey: .questions)
    }
    public func requestData(model: String = "jev-1.13.0") throws -> Data {
        struct Request: Encodable { let model: String; let state: String; let questions: [String: ChoiceQuestion] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Request(model: model, state: state, questions: questions))
    }
    public func digest() throws -> String { Self.hash(try requestData()) }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
public struct ChoiceAnswer: Codable, Sendable {
    public let choice: String
    public let confidence: Double?
    public let probabilities: [String: Double]?
    public init(choice: String, confidence: Double? = nil, probabilities: [String: Double]? = nil) {
        self.choice = choice; self.confidence = confidence; self.probabilities = probabilities
    }
}
public struct DecisionReceipt: Codable, Sendable {
    public let provider: String
    public let model: String
    /// Canonical decision-task digest: exact Jev HTTP bytes, or the same shared
    /// comparison representation for Apple (not Apple's private SDK wire body).
    public let requestSHA256: String
    public let answers: [String: ChoiceAnswer]
    public let elapsedSeconds: Double
    /// Genuine compact query provenance; never legacy choice answers.
    public let compactProductQueryReceipt: CompactProductQueryReceipt?
    public init(provider: String, model: String, requestSHA256: String, answers: [String: ChoiceAnswer], elapsedSeconds: Double) {
        self.provider = provider; self.model = model; self.requestSHA256 = requestSHA256; self.answers = answers; self.elapsedSeconds = elapsedSeconds; self.compactProductQueryReceipt = nil
    }
    public init(compactProductQueryReceipt receipt: CompactProductQueryReceipt) {
        provider=receipt.provider; model=receipt.model; requestSHA256=receipt.requestSHA256
        elapsedSeconds=receipt.elapsedSeconds; answers=[:]; compactProductQueryReceipt=receipt
    }
    public func validateCompactProductQuery(for task:CompactProductQueryTask)throws {
        guard let compactProductQueryReceipt,answers.isEmpty,provider==compactProductQueryReceipt.provider,
              model==compactProductQueryReceipt.model,requestSHA256==compactProductQueryReceipt.requestSHA256,
              elapsedSeconds==compactProductQueryReceipt.elapsedSeconds else{throw SemanticError.invalidReceipt}
        try compactProductQueryReceipt.validate(for:task)
    }
    public func validate(for task: ChoiceTask) throws {
        guard compactProductQueryReceipt==nil else{throw SemanticError.invalidReceipt}
        guard requestSHA256 == (try task.digest()), Set(answers.keys) == Set(task.questions.keys) else { throw SemanticError.invalidReceipt }
        if provider == "jev" { guard model == "jev-1.13.0" else { throw SemanticError.invalidReceipt } }
        for (id, answer) in answers {
            guard let question = task.questions[id], question.criteria[answer.choice] != nil else { throw SemanticError.invalidReceipt }
            if provider == "jev" {
                guard let confidence = answer.confidence, confidence.isFinite, (0...1).contains(confidence),
                      let probabilities = answer.probabilities, Set(probabilities.keys) == Set(question.criteria.keys),
                      probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                      let chosen = probabilities[answer.choice], chosen == probabilities.values.max() else { throw SemanticError.invalidReceipt }
                // Two-decimal distributions: tolerate only their rounding interval.
                let sum = probabilities.values.reduce(0, +), tolerance = Double(probabilities.count) * 0.005 + 1e-9
                guard abs(sum - 1) <= tolerance else { throw SemanticError.invalidReceipt }
            }
        }
    }
    public func choice(_ id: String) throws -> String {
        guard compactProductQueryReceipt==nil else{throw SemanticError.invalidReceipt}
        guard let answer = answers[id] else { throw SemanticError.invalidReceipt }
        if provider == "jev", (answer.confidence ?? 0) < 0.8 { throw SemanticError.lowConfidence(id) }
        return answer.choice
    }
}
public protocol DecisionProvider: Sendable { func decide(_ task: ChoiceTask) async throws -> DecisionReceipt }

/// Replays actual, retained provider receipts against exact task hashes. It is
/// explicit replay, not another inference call or authored model substitution.
public struct ReceiptProvider: DecisionProvider {
    private let receipts: [String: DecisionReceipt]
    public init(receipts: [String: DecisionReceipt]) { self.receipts = receipts }
    public func decide(_ task: ChoiceTask) async throws -> DecisionReceipt {
        guard let receipt = receipts[task.id] else { throw SemanticError.unavailable }
        try receipt.validate(for: task); return receipt
    }
}

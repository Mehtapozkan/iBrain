import Foundation
import IBrain

/// Ordinary descriptive fields only. Opaque record/source IDs and booking
/// references are deliberately unavailable to this text matching operation.
public enum EvidenceTextField:String,Codable,CaseIterable,Sendable {case title,provider,performer,venue,venueAddress}
public enum EvidenceTextOperation:String,Codable,Sendable {case contains,excludes}
public struct EvidenceTextPredicate:Codable,Equatable,Sendable {
    public let field:EvidenceTextField
    public let operation:EvidenceTextOperation
    public let questionQuote:String
    public init(field:EvidenceTextField,operation:EvidenceTextOperation,questionQuote:String){self.field=field;self.operation=operation;self.questionQuote=questionQuote}
    /// Nil means the field is unavailable, not that the condition is false.
    /// Negation retains unknown; it cannot promote a missing field to a match.
    public func evaluate(_ a:AppointmentProjection)->Bool? {
        let value:String?
        switch field {case .title:value=a.title;case .provider:value=a.provider;case .performer:value=a.performer;case .venue:value=a.venue;case .venueAddress:value=a.venueAddress}
        guard let value,!value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!questionQuote.isEmpty else{return nil}
        func words(_ text:String)->String{text.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX")).components(separatedBy:CharacterSet.alphanumerics.inverted).filter{!$0.isEmpty}.joined(separator:" ")}
        let needle=words(questionQuote)
        let found=needle.isEmpty ? value.range(of:questionQuote,options:[.caseInsensitive,.diacriticInsensitive]) != nil:(" "+words(value)+" ").contains(" "+needle+" ")
        return operation == .contains ? found:!found
    }
    public static func evaluateAll(_ predicates:[Self],in a:AppointmentProjection)->Bool? {
        var unknown=false
        for predicate in predicates {
            if let truth=predicate.evaluate(a) {if !truth{return false}}
            else{unknown=true}
        }
        return unknown ? nil:true
    }
}

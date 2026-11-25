import Foundation

/// Invocation-local reuse of the span parser's developer-defined patterns.
/// No source text, matches, facts, task or receipt is cached. Each parser call
/// owns its matcher, so simultaneous reads never share mutable cache state.
internal struct TemporalPatternMatcher {
    private var expressions:[String:NSRegularExpression]=[:]
    private let maximumEntries=32
    mutating func matches(_ pattern:String,in text:String)throws->[NSTextCheckingResult] {
        let expression:NSRegularExpression
        if let existing=expressions[pattern] {expression=existing}
        else {
            expression=try NSRegularExpression(pattern:pattern,options:.caseInsensitive)
            // Overflow preserves parsing behavior, with no eviction/refusal or
            // additional retained entries. Current grammars use fewer than32.
            if expressions.count<maximumEntries {expressions[pattern]=expression}
        }
        return expression.matches(in:text,range:NSRange(text.startIndex...,in:text))
    }
}

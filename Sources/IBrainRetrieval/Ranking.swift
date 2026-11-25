import Foundation

// Formula/tokenization derived from the pinned MIT gbrain-evals adapter.
// Actual upstream comparison, attribution and limitations are in the report.
enum SourceRanking {
    struct Document { let id: String; let text: String }
    struct Rank { let id: String; let score: Double }
    static let stopwords = Set("a an the and or but is are was were be been being have has had do does did will would should could may might can of to in on at for with by from as it its this that these those i you he she we they them us him her his hers their theirs my mine your yours our ours".split(separator: " ").map(String.init))
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isASCII || !($0.isLetter || $0.isNumber) }.map(String.init).filter { $0.count >= 2 && !stopwords.contains($0) }
    }
    static func sorted(_ ranks: [Rank]) -> [Rank] {
        ranks.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
    }
    static func lexical(_ documents: [Document], query: String) -> [Rank] {
        guard !documents.isEmpty else { return [] }
        let texts = documents.map { tokens($0.text) }, q = tokens(query)
        let avg = Double(texts.reduce(0) { $0 + $1.count }) / Double(documents.count)
        return sorted(zip(documents,texts).compactMap { doc, terms in
            guard !terms.isEmpty else { return nil }
            var score = 0.0
            for term in q {
                let tf = Double(terms.filter { $0 == term }.count)
                guard tf > 0 else { continue }
                let df = Double(texts.filter { $0.contains(term) }.count)
                let idf = log((Double(documents.count) - df + 0.5) / (df + 0.5) + 1)
                score += idf * (tf * 2.5) / (tf + 1.5 * (0.25 + 0.75 * Double(terms.count) / avg))
            }
            return score > 0 ? Rank(id: doc.id, score: score) : nil
        })
    }
    static func normalized(_ vector: [Double], space: TextVectorSpace) throws -> [Double] {
        guard space.isValid, vector.count == space.dimension, vector.allSatisfy(\.isFinite) else { throw SourceSearchError.invalidVector }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { throw SourceSearchError.invalidVector }
        return vector.map { $0 / norm }
    }
    static func semantic(_ vectors: [String: [Double]], query: [Double]) -> [Rank] {
        sorted(vectors.map { entry in
            Rank(id: entry.key, score: min(1, max(-1, zip(entry.value, query).reduce(0) { $0 + $1.0 * $1.1 })))
        })
    }
    static func hybrid(_ lexical: [Rank], _ semantic: [Rank]) -> [Rank] {
        var scores: [String: Double] = [:]
        for list in [lexical, semantic] { for (i, rank) in list.enumerated() { scores[rank.id, default: 0] += 1 / Double(61 + i) } }
        return sorted(scores.map { Rank(id: $0.key, score: $0.value) })
    }
}

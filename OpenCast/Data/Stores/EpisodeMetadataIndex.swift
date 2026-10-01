import Foundation

/// Okapi BM25 over each episode's title and kept description, with the
/// Lucene-style non-negative idf, `log(1 + (N - df + 0.5) / (df + 0.5))`,
/// k1 1.2 and b 0.75. Inverted postings, so a query touches only the lines
/// that share one of its terms. Immutable once built.
nonisolated struct EpisodeMetadataIndex: Sendable {
    static let termSaturation = 1.2
    static let lengthNormalization = 0.75

    private let positions: [Int]
    private let lengths: [Int]
    private let averageLength: Double
    private let postings: [String: [(document: Int, frequency: Int)]]

    init(lines: [EpisodeMetadataLine]) {
        var postings: [String: [(document: Int, frequency: Int)]] = [:]
        var lengths: [Int] = []
        lengths.reserveCapacity(lines.count)
        for (document, line) in lines.enumerated() {
            let tokens = EpisodeMetadataTokenizer.tokens(in: line.lexicalText)
            var frequencies: [String: Int] = [:]
            var order: [String] = []
            for token in tokens {
                if frequencies[token] == nil {
                    order.append(token)
                }
                frequencies[token, default: 0] += 1
            }
            for token in order {
                postings[token, default: []].append((document: document, frequency: frequencies[token, default: 0]))
            }
            lengths.append(tokens.count)
        }
        let total = lengths.reduce(0, +)
        let average = lines.isEmpty ? 0 : Double(total) / Double(lines.count)
        self.positions = lines.map(\.position)
        self.lengths = lengths
        self.averageLength = average == 0 ? 1 : average
        self.postings = postings
    }

    var documentCount: Int {
        positions.count
    }

    /// Lines with a positive score, best first, ties by position (newest first).
    func search(_ query: String, limit: Int) -> [EpisodeMetadataMatch] {
        guard limit > 0 else {
            return []
        }
        return Array(ranked(EpisodeMetadataTokenizer.queryTerms(query), keeping: nil).prefix(limit))
    }

    /// Query terms that appear in at least one line and in no more than half
    /// of them. A term in nearly every line (the show's own name) cannot
    /// narrow anything down; a term in no line matches nothing.
    func informativeTerms(_ query: String) -> [String] {
        EpisodeMetadataTokenizer.queryTerms(query).filter { term in
            let frequency = postings[term]?.count ?? 0
            return frequency >= 1 && 2 * frequency <= documentCount
        }
    }

    func isInformative(_ query: String) -> Bool {
        !informativeTerms(query).isEmpty
    }

    /// The full ranking for `query`, kept where the line holds an informative
    /// term: the lexical block of a candidate window, in BM25 order.
    func informativeMatches(_ query: String) -> [EpisodeMetadataMatch] {
        let informative = informativeTerms(query)
        guard !informative.isEmpty else {
            return []
        }
        var holdsInformativeTerm = [Bool](repeating: false, count: documentCount)
        for term in informative {
            for posting in postings[term] ?? [] {
                holdsInformativeTerm[posting.document] = true
            }
        }
        return ranked(EpisodeMetadataTokenizer.queryTerms(query), keeping: holdsInformativeTerm)
    }

    private func ranked(_ terms: [String], keeping kept: [Bool]?) -> [EpisodeMetadataMatch] {
        let count = documentCount
        guard count > 0, !terms.isEmpty else {
            return []
        }
        let k1 = Self.termSaturation
        let b = Self.lengthNormalization
        var scores = [Double](repeating: 0, count: count)
        for term in terms {
            guard let list = postings[term] else {
                continue
            }
            let idf = log(1 + (Double(count - list.count) + 0.5) / (Double(list.count) + 0.5))
            for posting in list {
                let frequency = Double(posting.frequency)
                let length = Double(lengths[posting.document])
                scores[posting.document] += idf * frequency * (k1 + 1)
                    / (frequency + k1 * (1 - b + b * length / averageLength))
            }
        }
        var matches: [EpisodeMetadataMatch] = []
        for (document, score) in scores.enumerated() where score > 0 && (kept?[document] ?? true) {
            matches.append(EpisodeMetadataMatch(position: positions[document], score: score))
        }
        return matches.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.position < rhs.position : lhs.score > rhs.score
        }
    }
}

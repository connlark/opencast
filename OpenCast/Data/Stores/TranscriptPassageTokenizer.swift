import Foundation

/// Folds transcript text and questions into comparable lexical tokens for
/// the passage index: case and diacritic insensitive, split on anything that
/// is not a letter or digit, possessives and plurals collapsed, and a small
/// list of function and filler words removed. Deliberately tiny; semantic
/// re-ranking is a later experiment, not this type's job.
nonisolated enum TranscriptPassageTokenizer {
    static let minimumTokenLength = 2

    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "by", "for", "with",
        "from", "as", "is", "are", "was", "were", "be", "been", "being", "am", "it", "its", "this",
        "that", "these", "those", "i", "you", "he", "she", "we", "they", "me", "him", "her", "us",
        "them", "my", "your", "his", "our", "their", "what", "which", "who", "whom", "when", "where",
        "why", "how", "do", "does", "did", "have", "has", "had", "not", "no", "so", "if", "then",
        "than", "there", "here", "about", "into", "up", "down", "out", "over", "just", "like",
        "um", "uh", "yeah", "yes", "okay", "ok", "oh", "well", "know", "think", "mean", "really",
        "very", "can", "could", "would", "should", "will", "get", "got", "go", "going", "say",
        "said", "says", "one", "thing", "also", "because", "right", "kind", "sort", "lot", "don",
        "ve", "ll", "re", "s", "t", "d", "m", "gonna", "wanna", "actually", "basically", "mentioned",
        "mention", "episode", "host", "hosts", "guest", "podcast", "talk", "talks", "talking", "discuss",
        "discussed", "according", "describe", "described", "explain", "explains", "tell", "tells",
    ]

    static func tokens(in text: String) -> [String] {
        let folded = text
            .replacing("’", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacing("'s ", with: " ")
        var tokens: [String] = []
        for raw in folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let token = stem(String(raw))
            guard token.count >= minimumTokenLength, !stopWords.contains(token) else {
                continue
            }
            tokens.append(token)
        }
        return tokens
    }

    /// Plural handling only: anything richer mangles too many short words.
    static func stem(_ token: String) -> String {
        if token.count > 4, token.hasSuffix("ies") {
            return String(token.dropLast(3)) + "y"
        }
        if token.count > 4, token.hasSuffix("sses") {
            return String(token.dropLast(2))
        }
        if token.count > 3, token.hasSuffix("s"),
           !token.hasSuffix("ss"), !token.hasSuffix("us"), !token.hasSuffix("is") {
            return String(token.dropLast())
        }
        return token
    }
}

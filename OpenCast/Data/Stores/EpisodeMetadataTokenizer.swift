import Foundation

/// The word-matching tokenizer for episode titles and descriptions:
/// compatibility-decomposed and folded to lowercase ASCII with word boundaries
/// preserved, possessive "'s"
/// removed, `[a-z0-9]+` runs, a short stop list checked before stemming,
/// then a light plural stemmer. Its behaviour is pinned by the ranking
/// tests; changing any step changes which episodes a request sends.
nonisolated enum EpisodeMetadataTokenizer {
    static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from",
        "has", "have", "in", "into", "is", "it", "its", "of", "on", "or",
        "the", "this", "that", "to", "with", "about", "episode", "episodes", "playlist", "playlists",
        "me", "my", "make", "some", "all", "any", "please",
    ]

    static func tokens(in text: String) -> [String] {
        let folded = Array(fold(text).utf8)
        var result: [String] = []
        var start: Int?
        for offset in 0...folded.count {
            if offset < folded.count, isWordByte(folded[offset]) {
                if start == nil {
                    start = offset
                }
            } else if let runStart = start {
                let raw = String(decoding: folded[runStart..<offset], as: UTF8.self)
                if !stopWords.contains(raw) {
                    result.append(stem(raw))
                }
                start = nil
            }
        }
        return result
    }

    /// Unique terms in first-occurrence order. Scores add up term by term, so
    /// a fixed order keeps every sum, and every exact tie, the same on each run;
    /// iterating a `Set` here would not.
    static func queryTerms(_ query: String) -> [String] {
        var seen = Set<String>()
        return tokens(in: query).filter { seen.insert($0).inserted }
    }

    static func stem(_ token: String) -> String {
        let count = token.utf8.count
        if count > 4, token.hasSuffix("ies") {
            return String(token.dropLast(3)) + "y"
        }
        if count > 3, token.hasSuffix("s"), !token.hasSuffix("ss"), !token.hasSuffix("us"), !token.hasSuffix("is") {
            return String(token.dropLast())
        }
        return token
    }

    /// The request with stop-listed words removed (whitespace split,
    /// punctuation-trimmed, lowercased compare); the raw query when nothing
    /// survives. The word-vector lane embeds this.
    static func strippingStopWords(_ query: String) -> String {
        let words = query.split(whereSeparator: \.isWhitespace).filter { word in
            !stopWords.contains(word.lowercased().trimmingCharacters(in: .punctuationCharacters))
        }
        return words.isEmpty ? query : words.joined(separator: " ")
    }

    private static func fold(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCompatibilityMapping.unicodeScalars {
            let value = scalar.value
            if scalar == "’" || scalar == "‘" {
                scalars.append("'")
            } else if CharacterSet.nonBaseCharacters.contains(scalar) {
                // Decomposed accents belong to the preceding letter.
                continue
            } else if !scalar.isASCII {
                scalars.append(" ")
            } else if value >= 65, value <= 90, let lower = Unicode.Scalar(value + 32) {
                scalars.append(lower)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars).replacing("'s ", with: " ")
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
    }
}

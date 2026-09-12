import Foundation

public enum OpenCastAdBoundaryResolver {
    public static let revision = "word-boundaries-v2"

    /// Unicode scalar rules mirror Rust's `char::is_alphanumeric` and lowercase.
    /// Keeping the owner of each normalized token avoids interpolating inside
    /// contractions, URLs, or other indivisible ASR words.
    public static func normalizedTokens(_ text: String) -> [String] {
        text.unicodeScalars.split {
            !$0.properties.isAlphabetic && $0.properties.numericType == nil
        }.map { String(String.UnicodeScalarView($0)).lowercased() }
    }

    public static func resolve(
        _ boundary: OpenCastAdBoundary?,
        in segment: OpenCastTranscriptSegment?,
        isStart: Bool,
        fallback: TimeInterval
    ) -> OpenCastAdBoundaryResolution {
        func fail(_ reason: String) -> OpenCastAdBoundaryResolution {
            .init(time: fallback, fallbackReason: reason)
        }
        guard let boundary else { return fail("missing_anchor") }
        guard boundary.quote.utf8.count <= 2048,
              let segment, segment.id == boundary.segmentID
        else { return fail("invalid_anchor") }
        guard segment.wordTimingsAdjusted != true else { return fail("adjusted_word_timing") }
        guard let words = segment.words, !words.isEmpty else { return fail("missing_words") }
        let source = normalizedTokens(segment.text)
        let quote = normalizedTokens(boundary.quote)
        guard !quote.isEmpty, quote.count <= 32, quote.count <= source.count else {
            return fail("invalid_quote")
        }
        var tokens: [String] = []
        var owners: [Int] = []
        var previousEnd = segment.start
        for (index, word) in words.enumerated() {
            guard word.start.isFinite, word.end.isFinite,
                  word.start >= previousEnd, word.end >= word.start,
                  word.start >= segment.start, word.end <= segment.end
            else { return fail("invalid_word_timing") }
            previousEnd = word.end
            let pieces = normalizedTokens(word.text)
            // Attached punctuation is allowed without requiring it to have a
            // duration. Every spoken token, however, must have a usable interval.
            guard pieces.isEmpty || word.end > word.start else {
                return fail("zero_duration_word")
            }
            tokens.append(contentsOf: pieces)
            owners.append(contentsOf: repeatElement(index, count: pieces.count))
        }
        guard tokens == source else { return fail("word_text_mismatch") }
        let matches = (0...(source.count - quote.count)).filter {
            Array(source[$0..<($0 + quote.count)]) == quote
        }
        guard matches.count == 1, let offset = matches.first else {
            return fail("ambiguous_or_missing_quote")
        }
        let tokenIndex = isStart ? offset : offset + quote.count - 1
        let owner = owners[tokenIndex]
        if isStart && tokenIndex > 0 && owners[tokenIndex - 1] == owner {
            return fail("partial_word_anchor")
        }
        if !isStart && tokenIndex + 1 < owners.count && owners[tokenIndex + 1] == owner {
            return fail("partial_word_anchor")
        }
        return .init(time: isStart ? words[owner].start : words[owner].end, wordIndex: owner)
    }
}

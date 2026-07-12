import Foundation

nonisolated enum TranscriptSearchMatcher {
    static let comparisonOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    static func matchRanges(of query: String, in text: String) -> [Range<String.Index>] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        var ranges: [Range<String.Index>] = []
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let range = text.range(of: trimmedQuery, options: comparisonOptions, range: cursor..<text.endIndex) {
            ranges.append(range)
            cursor = range.upperBound > cursor ? range.upperBound : text.index(after: cursor)
        }
        return ranges
    }
}

import Foundation
import OpenCastTranscription

/// Immutable search support built once per transcript document so that
/// per-keystroke matching runs off the main thread — the voice boost audio
/// tap renders in-process, so main-thread stalls are audible.
///
/// Candidate filtering scans pre-folded copies of every line; ICU only runs
/// for the (few) matched lines to produce highlight ranges into the original
/// text.
nonisolated struct TranscriptSearchIndex: Sendable {
    private let segments: [OpenCastTranscriptSegment]
    private let foldedTexts: [String]

    init(segments: [OpenCastTranscriptSegment]) {
        self.segments = segments
        foldedTexts = segments.map { Self.fold($0.text) }
    }

    func result(for query: String) -> TranscriptSearchResult {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let foldedQuery = Self.fold(trimmedQuery)
        guard !foldedQuery.isEmpty else {
            return TranscriptSearchResult(query: query)
        }

        var matchSegmentIDs: [Int] = []
        var highlightRanges: [Int: [Range<String.Index>]] = [:]
        for index in foldedTexts.indices where foldedTexts[index].contains(foldedQuery) {
            let segment = segments[index]
            matchSegmentIDs.append(segment.id)
            let ranges = TranscriptSearchMatcher.matchRanges(of: trimmedQuery, in: segment.text)
            if !ranges.isEmpty {
                highlightRanges[segment.id] = ranges
            }
        }
        return TranscriptSearchResult(
            query: query,
            matchSegmentIDs: matchSegmentIDs,
            highlightRangesBySegmentID: highlightRanges
        )
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

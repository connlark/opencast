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
    private static let cancellationCheckStride = 64

    private let segments: [OpenCastTranscriptSegment]
    private let foldedTexts: [String]

    private init(segments: [OpenCastTranscriptSegment], foldedTexts: [String]) {
        self.segments = segments
        self.foldedTexts = foldedTexts
    }

    @concurrent
    static func build(
        segments: [OpenCastTranscriptSegment],
        checkpoint: (@Sendable (Int) async -> Void)? = nil
    ) async throws -> TranscriptSearchIndex {
        try Task.checkCancellation()

        var foldedTexts: [String] = []
        foldedTexts.reserveCapacity(segments.count)
        for (offset, segment) in segments.enumerated() {
            if offset.isMultiple(of: cancellationCheckStride) {
                await checkpoint?(offset)
                try Task.checkCancellation()
            }
            foldedTexts.append(fold(segment.text))
        }

        try Task.checkCancellation()
        return TranscriptSearchIndex(segments: segments, foldedTexts: foldedTexts)
    }

    @concurrent
    func result(
        for query: String,
        checkpoint: (@Sendable (Int) async -> Void)? = nil
    ) async throws -> TranscriptSearchResult {
        try Task.checkCancellation()

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let foldedQuery = Self.fold(trimmedQuery)
        guard !foldedQuery.isEmpty else {
            return TranscriptSearchResult(query: query)
        }

        var matchSegmentIDs: [Int] = []
        var highlightRanges: [Int: [Range<String.Index>]] = [:]
        for index in foldedTexts.indices {
            if index.isMultiple(of: Self.cancellationCheckStride) {
                await checkpoint?(index)
                try Task.checkCancellation()
            }
            guard foldedTexts[index].contains(foldedQuery) else {
                continue
            }

            let segment = segments[index]
            matchSegmentIDs.append(segment.id)
            let ranges = TranscriptSearchMatcher.matchRanges(of: trimmedQuery, in: segment.text)
            if !ranges.isEmpty {
                highlightRanges[segment.id] = ranges
            }
        }

        try Task.checkCancellation()
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

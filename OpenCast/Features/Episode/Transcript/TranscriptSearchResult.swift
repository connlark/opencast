import Foundation

nonisolated struct TranscriptSearchResult: Equatable, Sendable {
    var query: String
    var matchSegmentIDs: [Int] = []
    var highlightRangesBySegmentID: [Int: [Range<String.Index>]] = [:]
}

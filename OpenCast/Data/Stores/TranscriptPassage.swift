import Foundation
import OpenCastTranscription

/// A run of consecutive transcript segments the passage index scores and the
/// Ask tools return as one unit. Citations still name individual segments,
/// so the tools print every segment line; the passage only decides what
/// travels together.
nonisolated struct TranscriptPassage: Identifiable, Equatable, Sendable {
    /// Position in the index, in transcript order.
    let id: Int
    let segments: [OpenCastTranscriptSegment]
    /// Folded, stemmed tokens with their counts, for BM25 scoring.
    let termFrequencies: [String: Int]
    let tokenCount: Int

    var firstSegmentID: Int {
        segments.first?.id ?? 0
    }

    var lastSegmentID: Int {
        segments.last?.id ?? 0
    }

    var start: TimeInterval {
        segments.first?.start ?? 0
    }

    var end: TimeInterval {
        segments.last?.end ?? 0
    }

    var segmentIDs: [Int] {
        segments.map(\.id)
    }

    func overlaps(_ range: ClosedRange<TimeInterval>) -> Bool {
        start <= range.upperBound && end >= range.lowerBound
    }
}

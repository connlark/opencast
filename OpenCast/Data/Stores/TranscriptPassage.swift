import Foundation
import OpenCastTranscription

/// Citations name individual segments, so a passage only decides which segment lines travel
/// together.
nonisolated struct TranscriptPassage: Identifiable, Equatable, Sendable {
    /// Position in the index, in transcript order.
    let id: Int
    let segments: [OpenCastTranscriptSegment]
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

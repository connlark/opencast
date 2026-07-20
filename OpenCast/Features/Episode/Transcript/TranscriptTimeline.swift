import Foundation
import OpenCastTranscription

nonisolated struct TranscriptTimeline: Equatable {
    let segments: [OpenCastTranscriptSegment]
    private let starts: [TimeInterval]

    init(segments: [OpenCastTranscriptSegment] = []) {
        self.segments = segments
        starts = segments.map(\.start)
    }

    var isEmpty: Bool {
        segments.isEmpty
    }

    /// Index of the last segment whose start is at or before `time`;
    /// nil before the first segment starts.
    func segmentIndex(at time: TimeInterval) -> Int? {
        Self.lastIndex(in: starts, atOrBefore: time)
    }

    /// Media time at which the next segment takes over; `.infinity` for the
    /// last segment, which stays active with no successor.
    func handoff(afterSegmentAt index: Int) -> TimeInterval {
        index + 1 < segments.count ? segments[index + 1].start : .infinity
    }

    /// Index of the last word in the segment whose start is at or before
    /// `time`; nil for line-level segments or before the first word starts.
    func wordIndex(in segmentIndex: Int, at time: TimeInterval) -> Int? {
        guard segments.indices.contains(segmentIndex),
              let words = segments[segmentIndex].words
        else {
            return nil
        }

        var result: Int?
        for (index, word) in words.enumerated() {
            guard word.start <= time else {
                break
            }
            result = index
        }
        return result
    }

    private static func lastIndex(in starts: [TimeInterval], atOrBefore time: TimeInterval) -> Int? {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low > 0 ? low - 1 : nil
    }
}

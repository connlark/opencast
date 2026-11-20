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

    func segmentIndex(at time: TimeInterval) -> Int? {
        Self.lastIndex(in: starts, atOrBefore: time)
    }

    func handoff(afterSegmentAt index: Int) -> TimeInterval {
        index + 1 < segments.count ? segments[index + 1].start : .infinity
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

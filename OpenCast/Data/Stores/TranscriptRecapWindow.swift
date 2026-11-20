import Foundation
import OpenCastTranscription

nonisolated struct TranscriptRecapWindow: Equatable, Sendable {
    var kind: TranscriptRecapWindowKind
    var playhead: TimeInterval
    var segments: [OpenCastTranscriptSegment]
    var promptText: String
    var tokenCount: Int
    var isTruncated: Bool

    var startTime: TimeInterval {
        segments.first?.start ?? playhead
    }

    var endTime: TimeInterval {
        min(segments.last?.end ?? playhead, playhead)
    }

    var segmentIDs: Set<Int> {
        Set(segments.map(\.id))
    }
}

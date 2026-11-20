import Foundation
import OpenCastTranscription

/// A seek can land fractionally before a tapped segment's start (whisper documents especially),
/// which would flick the follow-along highlight to the previous line for a beat.
nonisolated struct TranscriptTapPin: Equatable {
    let segment: OpenCastTranscriptSegment
    let segmentIndex: Int

    /// A position well before the pinned segment means the user seeked elsewhere.
    func shouldRelease(computedSegmentIndex: Int?, position: TimeInterval) -> Bool {
        if let computedSegmentIndex, computedSegmentIndex >= segmentIndex {
            return true
        }
        return position < segment.start - 3.0
    }
}

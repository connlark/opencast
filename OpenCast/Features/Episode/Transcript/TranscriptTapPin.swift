import Foundation
import OpenCastTranscription

/// Keeps a tapped line highlighted until playback catches up to it: a seek
/// can land fractionally before the segment's start (whisper documents in
/// particular), which would otherwise flick the follow-along highlight to
/// the previous line for a beat.
nonisolated struct TranscriptTapPin: Equatable {
    let segment: OpenCastTranscriptSegment
    let segmentIndex: Int

    /// Releases once playback reaches the pinned segment (or any later one),
    /// or once the position lands well before it — the user seeked elsewhere.
    func shouldRelease(computedSegmentIndex: Int?, position: TimeInterval) -> Bool {
        if let computedSegmentIndex, computedSegmentIndex >= segmentIndex {
            return true
        }
        return position < segment.start - 3.0
    }
}

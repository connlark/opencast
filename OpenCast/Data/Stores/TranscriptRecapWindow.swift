import Foundation
import OpenCastTranscription

/// The transcript slice one recap request sees: the segments in transcript
/// order (a "so far" window has non-adjacent sampled runs), the prompt text
/// built from them, and the on-device token count that sized it.
nonisolated struct TranscriptRecapWindow: Equatable, Sendable {
    var kind: TranscriptRecapWindowKind
    var playhead: TimeInterval
    var segments: [OpenCastTranscriptSegment]
    var promptText: String
    var tokenCount: Int
    /// Earlier segments were dropped to fit the token budget.
    var isTruncated: Bool

    var startTime: TimeInterval {
        segments.first?.start ?? playhead
    }

    var endTime: TimeInterval {
        min(segments.last?.end ?? playhead, playhead)
    }

    /// Ids a citation may name; anything else is dropped by the validator.
    var segmentIDs: Set<Int> {
        Set(segments.map(\.id))
    }
}

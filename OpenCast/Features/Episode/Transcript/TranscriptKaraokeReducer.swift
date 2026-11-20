import Foundation

/// Pure and idempotent over one absolute media position, so coalesced, duplicated or late
/// media-clock samples self-heal instead of permanently losing a word.
nonisolated enum TranscriptKaraokeReducer {
    struct Frame: Equatable {
        var segmentID: Int?
        var spokenUpperBound: String.Index?
    }

    static func frame(
        at position: TimeInterval,
        timeline: TranscriptTimeline,
        activeLayout: TranscriptKaraokeLayout?
    ) -> Frame {
        let segmentID = timeline.segmentIndex(at: position).map { timeline.segments[$0].id }
        guard let activeLayout, activeLayout.segmentID == segmentID else {
            return Frame(segmentID: segmentID, spokenUpperBound: nil)
        }
        return Frame(
            segmentID: segmentID,
            spokenUpperBound: activeLayout.spokenUpperBound(at: position)
        )
    }
}

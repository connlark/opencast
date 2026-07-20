import Foundation
import OpenCastTranscription
import os

/// Precomputed karaoke layout for one segment: each display-repaired word
/// onset paired with the end index of that word's text, resolved by a single
/// forward scan (the schema's word join invariant). Built once when a segment
/// becomes active so per-sample rendering never searches the string.
nonisolated struct TranscriptKaraokeLayout: Equatable, Sendable {
    #if DEBUG
    private static let logger = Logger(subsystem: "com.connor.opencast", category: "karaoke")
    #endif

    let segmentID: Int
    let text: String
    private let wordStarts: [TimeInterval]
    private let wordUpperBounds: [String.Index]

    /// nil when the segment has no words, display repair exceeds its fallback
    /// thresholds, or any word fails to scan — callers fall back to line-level
    /// rendering. `handoff` is the next segment's display start (`.infinity`
    /// for the last segment).
    init?(segment: OpenCastTranscriptSegment, handoff: TimeInterval) {
        guard let repaired = TranscriptKaraokeDisplayCues.repairedWords(
            for: segment,
            handoff: handoff
        ) else {
            return nil
        }
        #if DEBUG
        if !repaired.repairs.isEmpty {
            Self.logger.debug(
                "Segment \(segment.id) display repairs: \(String(describing: repaired.repairs))"
            )
        }
        #endif

        var starts: [TimeInterval] = []
        var upperBounds: [String.Index] = []
        var cursor = segment.text.startIndex
        for word in repaired.words {
            guard let range = segment.text.range(of: word.text, range: cursor..<segment.text.endIndex) else {
                return nil
            }
            cursor = range.upperBound
            starts.append(word.start)
            upperBounds.append(range.upperBound)
        }
        segmentID = segment.id
        text = segment.text
        wordStarts = starts
        wordUpperBounds = upperBounds
    }

    /// End index of the last word whose onset is at or before `time`;
    /// `text.startIndex` when nothing is spoken yet. Equal onsets share an
    /// upper bound scan order, so a whole group reveals in one lookup.
    func spokenUpperBound(at time: TimeInterval) -> String.Index {
        var low = 0
        var high = wordStarts.count
        while low < high {
            let mid = (low + high) / 2
            if wordStarts[mid] <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low > 0 ? wordUpperBounds[low - 1] : text.startIndex
    }
}

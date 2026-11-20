import Foundation
import OpenCastTranscription
import os

/// Built once when a segment becomes active, so per-sample rendering never searches the string.
/// The single forward scan relies on the schema's word join invariant.
nonisolated struct TranscriptKaraokeLayout: Equatable, Sendable {
    #if DEBUG
    private static let logger = Logger(subsystem: "com.connor.opencast", category: "karaoke")
    #endif

    let segmentID: Int
    let text: String
    private let wordStarts: [TimeInterval]
    private let wordUpperBounds: [String.Index]

    /// Nil when the segment has no words, repair exceeds its thresholds, or a word fails to scan.
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

    /// `text.startIndex` when nothing is spoken yet. A group of equal onsets reveals in one lookup.
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

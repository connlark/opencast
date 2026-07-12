import Foundation
import OpenCastTranscription

/// Precomputed karaoke layout for one segment: each word's start time paired
/// with the end index of that word's text, resolved by a single forward scan
/// (the schema's word join invariant). Built once when a segment becomes
/// active so per-flip rendering never searches the string.
nonisolated struct TranscriptKaraokeLayout: Equatable, Sendable {
    let segmentID: Int
    let text: String
    private let wordStarts: [TimeInterval]
    private let wordUpperBounds: [String.Index]

    /// nil when the segment has no words or any word fails to scan — callers
    /// fall back to line-level rendering.
    init?(segment: OpenCastTranscriptSegment) {
        guard let words = segment.words, !words.isEmpty else {
            return nil
        }

        var starts: [TimeInterval] = []
        var upperBounds: [String.Index] = []
        var cursor = segment.text.startIndex
        for word in words {
            guard !word.text.isEmpty,
                  let range = segment.text.range(of: word.text, range: cursor..<segment.text.endIndex)
            else {
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

    /// End index of the last word whose start is at or before `time`;
    /// `text.startIndex` when nothing is spoken yet.
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

    /// Wall-clock dates at which the spoken prefix next grows, given the
    /// current interpolation. Dates already in the past are ignored by
    /// TimelineView, so this can return the full word list unfiltered.
    func wordFlipDates(for interpolator: TranscriptPositionInterpolator) -> [Date] {
        guard interpolator.isPlaying, interpolator.rate > 0 else {
            return []
        }
        return wordStarts.map { start in
            interpolator.baseDate.addingTimeInterval((start - interpolator.basePosition) / interpolator.rate)
        }
    }
}

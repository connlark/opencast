import Foundation
import OpenCastTranscription

/// Presentation-only onset repair for karaoke display. The persisted document
/// keeps the engine's word timings; this derives, per active segment, onsets
/// that every word group can visibly reach before the next line takes over.
/// Unlike the persist normalizer it never floors an onset at the previous
/// word's end — noisy word ends are ignored, only onset order matters.
nonisolated enum TranscriptKaraokeDisplayCues {
    enum Repair: Equatable, Sendable {
        case droppedNonFinite
        case clampedToSegment
        case clampedToHandoff
        case nondecreasingEnforced
        case terminalGroupShifted
        case terminalGroupMerged
    }

    /// Minimum media-time exposure of the final onset group before handoff.
    static let minimumTerminalExposure: TimeInterval = 0.1
    /// Per-word correction beyond this means the timings are too wrong to
    /// present as word precision; callers fall back to line-level highlight.
    static let maximumOnsetCorrection: TimeInterval = 2.0
    static let maximumDroppedFraction: Double = 0.25

    /// nil when the segment has no words or repair would exceed the fallback
    /// thresholds. `handoff` is the next segment's display start, `.infinity`
    /// for the last segment (no successor, so late onsets can still render).
    static func repairedWords(
        for segment: OpenCastTranscriptSegment,
        handoff: TimeInterval
    ) -> (words: [OpenCastTranscriptWord], repairs: [Repair])? {
        guard let raw = segment.words, !raw.isEmpty else {
            return nil
        }

        var kept: [(word: OpenCastTranscriptWord, onset: TimeInterval)] = []
        var repairs: [Repair] = []
        var dropped = 0

        for word in raw {
            guard word.start.isFinite, word.end.isFinite, !word.text.isEmpty else {
                dropped += 1
                repairs.append(.droppedNonFinite)
                continue
            }
            var onset = word.start
            if onset < segment.start {
                onset = segment.start
                repairs.append(.clampedToSegment)
            }
            if handoff.isFinite, onset >= handoff {
                onset = handoff
                repairs.append(.clampedToHandoff)
            }
            kept.append((word, onset))
        }
        guard !kept.isEmpty,
              Double(dropped) <= Double(raw.count) * maximumDroppedFraction
        else {
            return nil
        }

        for index in 1..<kept.count where kept[index].onset < kept[index - 1].onset {
            kept[index].onset = kept[index - 1].onset
            repairs.append(.nondecreasingEnforced)
        }

        if handoff.isFinite {
            let target = handoff - minimumTerminalExposure
            // Equal onsets form one atomic group. Shift the terminal group back
            // into available slack; when the previous group is already later
            // than the target, merge into it and retry with the larger group.
            while let last = kept.last, last.onset > target {
                var groupStart = kept.count - 1
                while groupStart > 0, kept[groupStart - 1].onset == last.onset {
                    groupStart -= 1
                }
                let groupFloor = groupStart > 0 ? kept[groupStart - 1].onset : segment.start
                if target >= groupFloor {
                    for index in groupStart..<kept.count {
                        kept[index].onset = target
                    }
                    repairs.append(.terminalGroupShifted)
                    break
                } else if groupStart == 0 {
                    for index in kept.indices {
                        kept[index].onset = segment.start
                    }
                    repairs.append(.terminalGroupMerged)
                    break
                } else {
                    for index in groupStart..<kept.count {
                        kept[index].onset = groupFloor
                    }
                    repairs.append(.terminalGroupMerged)
                }
            }
        }

        for entry in kept where abs(entry.onset - entry.word.start) > maximumOnsetCorrection {
            return nil
        }

        let words = kept.map { entry in
            OpenCastTranscriptWord(
                start: entry.onset,
                end: max(entry.word.end, entry.onset),
                text: entry.word.text
            )
        }
        return (words, repairs)
    }
}

import Foundation
import OpenCastTranscription

enum OpenCastTranscriptSegmentNormalizer {
    nonisolated static func normalized(_ segments: [OpenCastTranscriptSegment]) -> [OpenCastTranscriptSegment] {
        var output: [OpenCastTranscriptSegment] = []
        output.reserveCapacity(segments.count)

        let finiteSegments = segments.enumerated().filter {
            $0.element.start.isFinite && $0.element.end.isFinite
        }
        let sortedSegments = finiteSegments.sorted { lhs, rhs in
            if lhs.element.start == rhs.element.start {
                return lhs.offset < rhs.offset
            }
            return lhs.element.start < rhs.element.start
        }

        for segment in sortedSegments {
            let text = segment.element.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }

            let rawStart = max(0, segment.element.start)
            let rawEnd = max(segment.element.end, rawStart)
            let start = max(rawStart, output.last?.end ?? rawStart)
            let end = max(rawEnd, start)
            output.append(OpenCastTranscriptSegment(
                id: output.count,
                start: start,
                end: end,
                text: text,
                avgLogProbability: segment.element.avgLogProbability,
                noSpeechProbability: segment.element.noSpeechProbability,
                words: normalizedWords(segment.element.words, within: start, end)
            ))
        }

        return output
    }

    nonisolated static func normalizedWords(
        _ words: [OpenCastTranscriptWord]?,
        within start: TimeInterval,
        _ end: TimeInterval
    ) -> [OpenCastTranscriptWord]? {
        guard let words else {
            return nil
        }

        var output: [OpenCastTranscriptWord] = []
        output.reserveCapacity(words.count)
        var previousEnd = start
        for word in words {
            guard word.start.isFinite, word.end.isFinite, !word.text.isEmpty else {
                continue
            }
            let wordStart = max(min(max(word.start, start), end), previousEnd)
            let wordEnd = min(max(word.end, wordStart), end)
            output.append(OpenCastTranscriptWord(start: wordStart, end: wordEnd, text: word.text))
            previousEnd = wordEnd
        }
        return output.isEmpty ? nil : output
    }
}

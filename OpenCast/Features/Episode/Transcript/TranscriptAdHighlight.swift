import Foundation
import OpenCastTranscription

nonisolated struct TranscriptAdHighlight {
    enum Coverage { case full, resolvedPartial, unresolvedPartial }

    let label: String
    let isStart: Bool
    let coverage: Coverage
    let ranges: [Range<String.Index>]
    let uncertainRanges: [Range<String.Index>]
    let isAutomaticSkip: Bool
    let hasUncertainCoverage: Bool

    var isWholeSegment: Bool { coverage == .full }

    init?(span: EpisodeAdAnalysisSpan, segment: OpenCastTranscriptSegment) {
        self.init(spans: [span], segment: segment)
    }

    init?(spans: [EpisodeAdAnalysisSpan], segment: OpenCastTranscriptSegment) {
        let overlapping = spans.filter { $0.startTime < segment.end && $0.endTime > segment.start }
        guard !overlapping.isEmpty else { return nil }
        let automatic = overlapping.filter { $0.confidence >= 0.8 }
        let primary = automatic.isEmpty ? overlapping : automatic
        isAutomaticSkip = !automatic.isEmpty
        label = Set(primary.map(\.label)).sorted().joined(separator: ", ")
        isStart = primary.contains { $0.startTime >= segment.start && $0.startTime < segment.end }
        var coveredEnd = segment.start
        for span in primary.sorted(by: { $0.startTime < $1.startTime }) {
            if span.startTime > coveredEnd { break }
            coveredEnd = max(coveredEnd, span.endTime)
        }
        let uncertain = overlapping.filter { $0.confidence < 0.8 }.flatMap { span in
            Self.uncovered(max(span.startTime, segment.start)..<min(span.endTime, segment.end), by: automatic)
        }
        hasUncertainCoverage = !uncertain.isEmpty
        if coveredEnd >= segment.end {
            coverage = .full
            ranges = []
            uncertainRanges = []
            return
        }
        guard let words = segment.words, !words.isEmpty,
              let display = Self.displayRanges(words: words, text: segment.text)
        else {
            coverage = .unresolvedPartial
            ranges = []
            uncertainRanges = []
            return
        }
        let selected = words.enumerated().compactMap { index, word -> Range<String.Index>? in
            guard word.end > word.start,
                  primary.contains(where: { word.start < $0.endTime && word.end > $0.startTime })
            else { return nil }
            return display[index]
        }
        // Selecting every spoken word does not establish whole-row time
        // coverage (silence and unaligned text can occupy the remaining time).
        coverage = selected.isEmpty ? .unresolvedPartial : .resolvedPartial
        ranges = selected
        uncertainRanges = automatic.isEmpty ? [] : words.enumerated().compactMap { index, word in
            guard word.end > word.start,
                  !automatic.contains(where: { word.start < $0.endTime && word.end > $0.startTime }),
                  uncertain.contains(where: { word.start < $0.upperBound && word.end > $0.lowerBound })
            else { return nil }
            return display[index]
        }
    }

    private static func uncovered(_ interval: Range<Double>, by automatic: [EpisodeAdAnalysisSpan]) -> [Range<Double>] {
        var pieces = [interval]
        for span in automatic {
            pieces = pieces.flatMap { piece in
                guard span.startTime < piece.upperBound, span.endTime > piece.lowerBound else { return [piece] }
                var tails: [Range<Double>] = []
                if piece.lowerBound < span.startTime { tails.append(piece.lowerBound..<span.startTime) }
                if span.endTime < piece.upperBound { tails.append(span.endTime..<piece.upperBound) }
                return tails
            }
        }
        return pieces
    }

    private static func displayRanges(words: [OpenCastTranscriptWord], text: String) -> [Range<String.Index>?]? {
        let pieces = text.unicodeScalars.split {
            !$0.properties.isAlphabetic && $0.properties.numericType == nil
        }
        let source = pieces.map { String(String.UnicodeScalarView($0)).lowercased() }
        var cursor = 0
        var ranges: [Range<String.Index>?] = []
        for word in words {
            let tokens = OpenCastAdBoundaryResolver.normalizedTokens(word.text)
            guard cursor + tokens.count <= source.count,
                  Array(source[cursor..<(cursor + tokens.count)]) == tokens
            else { return nil }
            if tokens.isEmpty {
                ranges.append(nil)
            } else {
                ranges.append(pieces[cursor].startIndex..<pieces[cursor + tokens.count - 1].endIndex)
            }
            cursor += tokens.count
        }
        return cursor == source.count ? ranges : nil
    }
}

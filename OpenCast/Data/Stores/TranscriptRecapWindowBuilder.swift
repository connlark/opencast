import Foundation
import OpenCastTranscription

/// Selects the segments a recap covers and trims them to a token budget
/// measured with the on-device tokenizer, which matches PCC's count. Trimming
/// always drops the earliest segments, so a "so far" window loses its oldest
/// samples before any of its recent fifteen minutes.
nonisolated enum TranscriptRecapWindowBuilder {
    static let defaultTokenBudget = 6_000
    static let minimumTokenBudget = 1_000
    static let lastFiveMinutesSpan: TimeInterval = 5 * 60
    static let soFarRecentSpan: TimeInterval = 15 * 60
    static let soFarSampleStride: TimeInterval = 5 * 60
    static let soFarSampleSpan: TimeInterval = 60
    /// Segment ids are consecutive; a jump marks an omitted stretch.
    static let gapMarker = "[…]"

    private static let maximumTrimPasses = 6
    private static let estimatedCharactersPerToken = 4
    private static let promptTimeLocale = Locale(identifier: "en_US_POSIX")

    /// The segments the window would cover before any budgeting; nil when
    /// the listener has not played far enough for the kind or no transcript
    /// precedes the playhead. A transcript shorter than the playhead (the
    /// audio outran it, or it is simply short) is covered to its end.
    static func candidateSegments(
        kind: TranscriptRecapWindowKind,
        segments: [OpenCastTranscriptSegment],
        playhead: TimeInterval
    ) -> [OpenCastTranscriptSegment]? {
        guard playhead >= kind.minimumPlayhead, let last = segments.last else {
            return nil
        }
        let end = min(playhead, last.end)
        let intervals = coveredIntervals(kind: kind, end: end)
        let picked = segments.filter { segment in
            segment.start < end && intervals.contains { interval in
                segment.start < interval.upperBound && segment.end > interval.lowerBound
            }
        }
        return picked.isEmpty ? nil : picked
    }

    static func build(
        kind: TranscriptRecapWindowKind,
        segments: [OpenCastTranscriptSegment],
        playhead: TimeInterval,
        tokenBudget: Int = defaultTokenBudget,
        tokenCount: (String) async throws -> Int
    ) async throws -> TranscriptRecapWindow? {
        guard var picked = candidateSegments(kind: kind, segments: segments, playhead: playhead) else {
            return nil
        }
        let budget = max(tokenBudget, minimumTokenBudget)
        var text = promptText(for: picked)
        var count = try await tokenCount(text)
        var isTruncated = false
        var passes = 0
        while count > budget, picked.count > 1, passes < maximumTrimPasses {
            passes += 1
            try Task.checkCancellation()
            let keepFraction = Double(budget) / Double(count) * 0.9
            let targetCharacters = Int(Double(text.count) * keepFraction)
            picked.removeFirst(dropCount(from: picked, toFitCharacters: targetCharacters))
            isTruncated = true
            text = promptText(for: picked)
            count = try await tokenCount(text)
        }
        if count > budget, picked.count > 1 {
            // The tokenizer keeps disagreeing with the proportional estimate;
            // fall back to a character estimate so the loop stays bounded.
            let targetCharacters = budget * estimatedCharactersPerToken
            picked.removeFirst(dropCount(from: picked, toFitCharacters: targetCharacters))
            isTruncated = true
            text = promptText(for: picked)
            count = try await tokenCount(text)
        }
        return TranscriptRecapWindow(
            kind: kind,
            playhead: min(playhead, segments.last?.end ?? playhead),
            segments: picked,
            promptText: text,
            tokenCount: count,
            isTruncated: isTruncated
        )
    }

    /// One line per segment, `[#id m:ss] text`, with a gap marker wherever
    /// the ids jump so the model knows a stretch was omitted.
    static func promptText(for segments: [OpenCastTranscriptSegment]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(segments.count)
        var previousID: Int?
        for segment in segments {
            if let previousID, segment.id != previousID + 1 {
                lines.append(gapMarker)
            }
            lines.append(line(for: segment))
            previousID = segment.id
        }
        return lines.joined(separator: "\n")
    }

    private static func line(for segment: OpenCastTranscriptSegment) -> String {
        let time = segment.start.formattedPlaybackDuration(locale: promptTimeLocale)
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[#\(segment.id) \(time)] \(text)"
    }

    private static func coveredIntervals(
        kind: TranscriptRecapWindowKind,
        end: TimeInterval
    ) -> [ClosedRange<TimeInterval>] {
        switch kind {
        case .lastFiveMinutes:
            return [max(0, end - lastFiveMinutesSpan)...end]
        case .soFar:
            let recentStart = max(0, end - soFarRecentSpan)
            var intervals: [ClosedRange<TimeInterval>] = []
            var sampleStart: TimeInterval = 0
            while sampleStart + soFarSampleSpan <= recentStart {
                intervals.append(sampleStart...(sampleStart + soFarSampleSpan))
                sampleStart += soFarSampleStride
            }
            intervals.append(recentStart...end)
            return intervals
        }
    }

    /// How many leading segments to drop so the remaining prompt text is at
    /// most `targetCharacters` long; always leaves one segment.
    private static func dropCount(
        from segments: [OpenCastTranscriptSegment],
        toFitCharacters targetCharacters: Int
    ) -> Int {
        var remaining = segments.reduce(0) { $0 + line(for: $1).count + 1 }
        var dropped = 0
        while remaining > targetCharacters, dropped < segments.count - 1 {
            remaining -= line(for: segments[dropped]).count + 1
            dropped += 1
        }
        return max(dropped, 1)
    }
}

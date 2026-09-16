import Foundation
import OpenCastTranscription

/// Renders transcript segments for the model: one `[#id m:ss–m:ss] text` line
/// per segment, blocks separated by a blank line, prefixed by the data
/// framing and cut at a token budget measured with the on-device tokenizer.
/// The same `[#id` prefix is what citation validation parses back out of a
/// tool exchange, so the two must agree.
nonisolated enum TranscriptToolOutput {
    static let defaultTokenBudget = 3_000
    static let noMatchesMessage =
        "No passages matched. Try two or three different distinctive words, or answer that the transcript does not cover it."

    struct Rendering: Equatable, Sendable {
        var text: String
        var shownSegmentIDs: [Int]
        var isTruncated: Bool
    }

    private static let timeLocale = Locale(identifier: "en_US_POSIX")
    private static let maximumTrimPasses = 8

    static func line(for segment: OpenCastTranscriptSegment) -> String {
        let start = segment.start.formattedPlaybackDuration(locale: timeLocale)
        let end = segment.end.formattedPlaybackDuration(locale: timeLocale)
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[#\(segment.id) \(start)–\(end)] \(text)"
    }

    /// Ids of every segment line in a rendered output, in order.
    static func segmentIDs(in output: String) -> [Int] {
        output.split(separator: "\n").compactMap { line -> Int? in
            guard line.hasPrefix("[#") else {
                return nil
            }
            let digits = line.dropFirst(2).prefix { $0.isNumber }
            guard !digits.isEmpty, line.dropFirst(2 + digits.count).first == " " else {
                return nil
            }
            return Int(digits)
        }
    }

    /// Adds whole blocks while they fit, then trims the block that overran
    /// line by line so the output always carries at least one segment.
    static func render(
        blocks: [[OpenCastTranscriptSegment]],
        tokenBudget: Int = defaultTokenBudget,
        tokenCount: (String) async throws -> Int
    ) async throws -> Rendering {
        var text = TranscriptIntelligencePrompts.transcriptDataFraming
        var shown: [Int] = []
        var isTruncated = false
        for block in blocks where !block.isEmpty {
            try Task.checkCancellation()
            var lines = block.map(line(for:))
            var candidate = text + "\n\n" + lines.joined(separator: "\n")
            var count = try await tokenCount(candidate)
            if count <= tokenBudget {
                text = candidate
                shown.append(contentsOf: block.map(\.id))
                continue
            }
            isTruncated = true
            guard shown.isEmpty else {
                break
            }
            var passes = 0
            while count > tokenBudget, lines.count > 1, passes < maximumTrimPasses {
                passes += 1
                let keep = max(1, Int(Double(lines.count) * Double(tokenBudget) / Double(count) * 0.9))
                lines = Array(lines.prefix(keep))
                candidate = text + "\n\n" + lines.joined(separator: "\n")
                count = try await tokenCount(candidate)
            }
            text = candidate
            shown.append(contentsOf: block.prefix(lines.count).map(\.id))
            break
        }
        return Rendering(text: text, shownSegmentIDs: shown, isTruncated: isTruncated)
    }
}

import Foundation
import OpenCastTranscription

/// Synthetic text/times for the offline UI regression; no model or media fetch.
enum OpenCastUITestWordBoundaryFixture {
    static let environmentKey = "OPENCAST_SEED_WORD_BOUNDARY_AD_ANALYSIS"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    static let segment: OpenCastTranscriptSegment = {
        let text = "This row is brought to you by Seed Sponsor. The show resumes."
        let words = text.split(separator: " ").enumerated().map { index, word in
            OpenCastTranscriptWord(
                start: 4 + Double(index) * 0.4,
                end: 4 + Double(index + 1) * 0.4,
                text: String(word)
            )
        }
        return OpenCastTranscriptSegment(
            id: 1, start: 4, end: 9, text: text,
            avgLogProbability: -0.1, noSpeechProbability: 0.01, words: words
        )
    }()

    static func anchored(_ span: EpisodeAdAnalysisSpan) -> EpisodeAdAnalysisSpan {
        var result = span
        result.startBoundary = .init(segmentID: 1, quote: "This row is brought")
        result.endBoundary = .init(segmentID: 1, quote: "Seed Sponsor")
        return result
    }
}

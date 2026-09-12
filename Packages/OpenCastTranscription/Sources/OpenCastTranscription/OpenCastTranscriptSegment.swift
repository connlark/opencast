import Foundation

public struct OpenCastTranscriptSegment: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var avgLogProbability: Double
    public var noSpeechProbability: Double
    /// Word-level timings in absolute episode seconds, ordered, within
    /// `[start, end]`. Non-nil only when every word in `text` is covered;
    /// joining the word texts under Apple's join rules (space-joined except
    /// attached punctuation `.,;:!?)]}%`) reconstructs `text`.
    public var words: [OpenCastTranscriptWord]?
    /// Sticky provenance: repaired word times remain usable for display, not
    /// precise ad cuts. Nil preserves compatibility with older transcripts.
    public var wordTimingsAdjusted: Bool?

    public init(
        id: Int,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        avgLogProbability: Double,
        noSpeechProbability: Double,
        words: [OpenCastTranscriptWord]? = nil,
        wordTimingsAdjusted: Bool? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.avgLogProbability = avgLogProbability
        self.noSpeechProbability = noSpeechProbability
        self.words = words
        self.wordTimingsAdjusted = wordTimingsAdjusted
    }
}

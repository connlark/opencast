import Foundation

public struct OpenCastTranscriptSegment: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var avgLogProbability: Double
    public var noSpeechProbability: Double
    /// Absolute episode seconds, ordered, within `[start, end]`. Non-nil only when the words
    /// cover all of `text`: joined with spaces, except before attached punctuation
    /// (`.,;:!?)]}%`), they reconstruct it.
    public var words: [OpenCastTranscriptWord]?
    /// Sticky: repaired word times are fine for display but not for precise ad cuts.
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

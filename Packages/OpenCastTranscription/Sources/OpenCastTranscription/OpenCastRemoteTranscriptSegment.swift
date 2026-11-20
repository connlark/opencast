public struct OpenCastRemoteTranscriptSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [OpenCastRemoteTranscriptWord]?
    public var wordTimingsAdjusted: Bool?

    public init(
        id: Int,
        start: Double,
        end: Double,
        text: String,
        words: [OpenCastRemoteTranscriptWord]? = nil,
        wordTimingsAdjusted: Bool? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.wordTimingsAdjusted = wordTimingsAdjusted
    }

    enum CodingKeys: String, CodingKey {
        case id, start, end, text, words
        case wordTimingsAdjusted = "word_timings_adjusted"
    }
}

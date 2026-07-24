/// One detected ad span inside a chained cloud ad analysis. `kind` stays a
/// raw wire string here; the app maps it to its strict span-kind enum at
/// import and treats anything unrecognized as a failed analysis rather than
/// skippable audio.
public struct OpenCastRemoteTranscriptionAdAnalysisSpan: Codable, Sendable, Equatable {
    public var kind: String
    public var label: String
    public var startSegmentID: Int
    public var endSegmentID: Int
    public var startTime: Double
    public var endTime: Double
    public var confidence: Double
    public var evidenceQuote: String

    public init(
        kind: String,
        label: String,
        startSegmentID: Int,
        endSegmentID: Int,
        startTime: Double,
        endTime: Double,
        confidence: Double,
        evidenceQuote: String
    ) {
        self.kind = kind
        self.label = label
        self.startSegmentID = startSegmentID
        self.endSegmentID = endSegmentID
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.evidenceQuote = evidenceQuote
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case label
        case startSegmentID = "start_segment_id"
        case endSegmentID = "end_segment_id"
        case startTime = "start_time"
        case endTime = "end_time"
        case confidence
        case evidenceQuote = "evidence_quote"
    }
}

public struct OpenCastTranscriptionResult: Codable, Sendable, Equatable {
    public var modelIdentifier: String
    public var languageCode: String
    public var text: String
    public var segments: [OpenCastTranscriptSegment]
    public var timings: OpenCastTranscriptionTimings

    public init(
        modelIdentifier: String,
        languageCode: String,
        text: String,
        segments: [OpenCastTranscriptSegment],
        timings: OpenCastTranscriptionTimings
    ) {
        self.modelIdentifier = modelIdentifier
        self.languageCode = languageCode
        self.text = text
        self.segments = segments
        self.timings = timings
    }
}

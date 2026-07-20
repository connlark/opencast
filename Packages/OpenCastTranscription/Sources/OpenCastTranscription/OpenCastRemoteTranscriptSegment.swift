/// One stitched segment in a remote transcription result. Word timings nest
/// per segment, mirroring the persisted document shape; there is no top-level
/// word list.
public struct OpenCastRemoteTranscriptSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [OpenCastRemoteTranscriptWord]?

    public init(
        id: Int,
        start: Double,
        end: Double,
        text: String,
        words: [OpenCastRemoteTranscriptWord]? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

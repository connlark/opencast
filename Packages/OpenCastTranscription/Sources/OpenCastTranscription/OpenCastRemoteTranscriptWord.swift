/// One word timing in a remote transcription result, in absolute episode
/// seconds after server-side stitching.
public struct OpenCastRemoteTranscriptWord: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

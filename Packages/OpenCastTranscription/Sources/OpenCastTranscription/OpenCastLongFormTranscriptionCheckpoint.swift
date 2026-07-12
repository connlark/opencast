import Foundation

public struct OpenCastLongFormTranscriptionCheckpoint: Sendable, Equatable {
    public var index: Int
    public var audioDuration: TimeInterval
    public var completedDuration: TimeInterval
    public var segments: [OpenCastTranscriptSegment]
    public var text: String

    public init(
        index: Int,
        audioDuration: TimeInterval,
        completedDuration: TimeInterval,
        segments: [OpenCastTranscriptSegment],
        text: String
    ) {
        self.index = index
        self.audioDuration = audioDuration
        self.completedDuration = completedDuration
        self.segments = segments
        self.text = text
    }
}

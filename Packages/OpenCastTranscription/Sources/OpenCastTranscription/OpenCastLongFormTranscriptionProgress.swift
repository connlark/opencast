import Foundation

public struct OpenCastLongFormTranscriptionProgress: Sendable, Equatable {
    public var audioDuration: TimeInterval
    public var completedDuration: TimeInterval
    public var checkpointCount: Int
    public var currentWindowIndex: Int?
    public var currentText: String?

    public init(
        audioDuration: TimeInterval,
        completedDuration: TimeInterval,
        checkpointCount: Int,
        currentWindowIndex: Int? = nil,
        currentText: String? = nil
    ) {
        self.audioDuration = audioDuration
        self.completedDuration = completedDuration
        self.checkpointCount = checkpointCount
        self.currentWindowIndex = currentWindowIndex
        self.currentText = currentText
    }
}

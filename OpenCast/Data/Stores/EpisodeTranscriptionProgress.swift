import Foundation

struct EpisodeTranscriptionProgress: Sendable, Equatable {
    var audioDuration: TimeInterval
    var completedDuration: TimeInterval
    var checkpointCount: Int
    var currentWindowIndex: Int?
    var currentText: String?

    var fractionCompleted: Double? {
        guard audioDuration > 0 else {
            return nil
        }
        return min(max(completedDuration / audioDuration, 0), 1)
    }
}

import Foundation

nonisolated struct EpisodeTranscriptAnalysisAPISegment: Codable, Sendable, Equatable {
    var id: Int
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

import Foundation

nonisolated struct EpisodeTranscriptCheckpoint: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var completedDuration: TimeInterval
    var segmentCount: Int
    var createdAt: Date
}

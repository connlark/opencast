import Foundation

nonisolated struct EpisodeTranscriptAnalysisClaim: Codable, Sendable, Equatable {
    var text: String
    var evidenceSegmentID: Int
}

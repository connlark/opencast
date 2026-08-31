import Foundation

nonisolated struct EpisodeTranscriptAnalysisSummary: Codable, Sendable, Equatable {
    var summary: String
    var oneLineDescription: String
    var claims: [EpisodeTranscriptAnalysisClaim]
}

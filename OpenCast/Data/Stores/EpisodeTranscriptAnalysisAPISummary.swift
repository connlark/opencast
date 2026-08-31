import Foundation

nonisolated struct EpisodeTranscriptAnalysisAPISummary: Codable, Sendable, Equatable {
    var summary: String
    var oneLineDescription: String
    var claims: [EpisodeTranscriptAnalysisAPIClaim]

    enum CodingKeys: String, CodingKey {
        case summary
        case oneLineDescription = "one_line_description"
        case claims
    }
}

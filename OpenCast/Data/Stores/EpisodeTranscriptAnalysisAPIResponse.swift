import Foundation

nonisolated struct EpisodeTranscriptAnalysisAPIResponse: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var requestID: String
    var model: String
    var policy: String
    var chapters: [EpisodeTranscriptAnalysisAPIChapter]
    var summary: EpisodeTranscriptAnalysisAPISummary?
    var warnings: [String]
    var usage: EpisodeTranscriptAnalysisAPIUsage?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case model
        case policy
        case chapters
        case summary
        case warnings
        case usage
    }
}

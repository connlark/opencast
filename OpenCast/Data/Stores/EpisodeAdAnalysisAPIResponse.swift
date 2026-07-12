import Foundation

nonisolated struct EpisodeAdAnalysisAPIResponse: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var requestID: String
    var model: String
    var policy: String
    var spans: [EpisodeAdAnalysisAPIAdSpan]
    var warnings: [String]
    var usage: EpisodeAdAnalysisAPIUsage?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case model
        case policy
        case spans
        case warnings
        case usage
    }
}

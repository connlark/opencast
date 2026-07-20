import Foundation

nonisolated struct EpisodeAdAnalysisJobPollRequest: Codable, Sendable, Equatable {
    var jobID: String

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
    }
}

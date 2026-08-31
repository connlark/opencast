import Foundation

nonisolated struct EpisodeTranscriptAnalysisJobPollRequest: Codable, Sendable, Equatable {
    var jobID: String

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
    }
}

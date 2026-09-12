import Foundation

nonisolated struct EpisodeAdAnalysisAPIRequest: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var requestID: String
    var episodeID: String
    var podcastID: String
    var episodeTitle: String?
    var podcastTitle: String?
    var asyncSupported: Bool? = nil
    var retryFailed: Bool? = nil
    var jobHandleVersion: Int? = 1
    var transcript: EpisodeAdAnalysisAPITranscriptMetadata
    var segments: [EpisodeAdAnalysisAPISegment]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case episodeID = "episode_id"
        case podcastID = "podcast_id"
        case episodeTitle = "episode_title"
        case podcastTitle = "podcast_title"
        case asyncSupported = "async_supported"
        case retryFailed = "retry_failed"
        case jobHandleVersion = "job_handle_version"
        case transcript
        case segments
    }
}

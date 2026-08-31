import Foundation

nonisolated struct EpisodeTranscriptAnalysisAPIRequest: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var requestID: String
    var episodeID: String
    var podcastID: String
    /// Real titles, never nil (decision H2): they anchor summaries, and the
    /// pinned prompt was validated with titles present.
    var episodeTitle: String?
    var podcastTitle: String?
    var asyncSupported: Bool? = nil
    /// Sharing consent (E1): true only while the sharing feature flag is
    /// live. Dark (always false) until E2 flips.
    var allowShared: Bool
    var transcript: EpisodeTranscriptAnalysisAPITranscriptMetadata
    var segments: [EpisodeTranscriptAnalysisAPISegment]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case episodeID = "episode_id"
        case podcastID = "podcast_id"
        case episodeTitle = "episode_title"
        case podcastTitle = "podcast_title"
        case asyncSupported = "async_supported"
        case allowShared = "allow_shared"
        case transcript
        case segments
    }
}

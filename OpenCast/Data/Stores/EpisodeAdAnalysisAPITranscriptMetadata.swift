import Foundation

nonisolated struct EpisodeAdAnalysisAPITranscriptMetadata: Codable, Sendable, Equatable {
    var languageCode: String
    var audioDuration: TimeInterval
    /// The feed's declared runtime (`<itunes:duration>`), when cached. The
    /// server sizes its episode ad budget by how much longer the served file
    /// runs than this; omitted when unknown.
    var declaredDuration: TimeInterval? = nil
    var modelIdentifier: String?
    var modelVersion: String?
    var modelTreeSHA256: String?
    var fingerprint: String
    var updatedAt: Date
    var state: String
    var segmentCount: Int

    enum CodingKeys: String, CodingKey {
        case languageCode = "language_code"
        case audioDuration = "audio_duration"
        case declaredDuration = "declared_duration"
        case modelIdentifier = "model_identifier"
        case modelVersion = "model_version"
        case modelTreeSHA256 = "model_tree_sha256"
        case fingerprint
        case updatedAt = "updated_at"
        case state
        case segmentCount = "segment_count"
    }
}

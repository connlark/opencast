import Foundation
import OpenCastTranscription

nonisolated struct EpisodeTranscriptDocument: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var episodeID: String
    var podcastID: String
    var sourceAudioURL: String
    var sourceFileByteCount: Int64
    var sourceFileSHA256: String
    var modelIdentifier: String
    var modelVersion: String
    var modelTreeSHA256: String
    var languageCode: String
    var audioDuration: TimeInterval
    var checkpoints: [EpisodeTranscriptCheckpoint]
    var segments: [OpenCastTranscriptSegment]
    var text: String
    var timings: EpisodeTranscriptTimings
    var createdAt: Date
    var updatedAt: Date
}

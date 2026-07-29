import Foundation
import OpenCastTranscription

nonisolated struct EpisodeTranscriptDocument: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 3

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

    // Schema 3 additive provenance. All optional so schema 1/2 documents keep
    // decoding; `modelIdentifier`/`modelVersion` continue to carry honest
    // compatibility values for older logic, and remote documents never claim
    // a local model tree hash (`modelTreeSHA256` stays empty for them).
    var transcriptionEngine: String? = nil
    var providerModelIdentifier: String? = nil
    var providerModelRevision: String? = nil
    var remoteServingContractVersion: String? = nil
    var remotePipelineVersion: String? = nil
    var remoteRequestSettingsSHA256: String? = nil
    var remoteChunkManifestSHA256: String? = nil
    var normalizedTranscriptSHA256: String? = nil
    var remoteJobProvenanceToken: String? = nil
    var remoteSourceMatchMode: String? = nil
}

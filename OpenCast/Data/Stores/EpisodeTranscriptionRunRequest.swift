import Foundation
import OpenCastTranscription

struct EpisodeTranscriptionRunRequest: Sendable, Equatable {
    var engine: EpisodeTranscriptionEngine = .whisper
    var audioFileURL: URL
    var languageCode: String
    var resumeStart: TimeInterval?
    var sourceAudioURL: String
    var sourceFileByteCount: Int64
    var sourceFileSHA256: String
    var modelIdentifier: String
    var modelVersion: String
    var modelTreeSHA256: String
    var computeProfile: OpenCastTranscriptionComputeProfile = .backgroundSafe
}

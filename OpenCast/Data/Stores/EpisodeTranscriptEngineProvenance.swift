import Foundation
import OpenCastTranscription

/// Which engine family produced a document; `EpisodeTranscriptionEngine` instead selects the
/// local run machinery.
nonisolated enum EpisodeTranscriptEngineProvenance: String, Codable, Sendable {
    case localWhisper = "local_whisper"
    case appleSpeech = "apple_speech"
    case remoteWhisper = "remote_whisper"

    /// For documents written before schema 3, which carry only a model identifier.
    static func inferred(fromModelIdentifier modelIdentifier: String) -> Self {
        if modelIdentifier.hasPrefix(AppleSpeechTranscriptionService.modelIdentifierPrefix) {
            .appleSpeech
        } else {
            .localWhisper
        }
    }
}

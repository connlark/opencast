import Foundation
import OpenCastTranscription

/// Persisted transcript provenance: which engine family produced a document
/// or record. Distinct from `EpisodeTranscriptionEngine`, which selects the
/// local run machinery; remote transcripts never run through that machinery.
nonisolated enum EpisodeTranscriptEngineProvenance: String, Codable, Sendable {
    case localWhisper = "local_whisper"
    case appleSpeech = "apple_speech"
    case remoteWhisper = "remote_whisper"

    /// Provenance for documents/records written before schema 3, which carry
    /// only a model identifier.
    static func inferred(fromModelIdentifier modelIdentifier: String) -> Self {
        if modelIdentifier.hasPrefix(AppleSpeechTranscriptionService.modelIdentifierPrefix) {
            .appleSpeech
        } else {
            .localWhisper
        }
    }
}

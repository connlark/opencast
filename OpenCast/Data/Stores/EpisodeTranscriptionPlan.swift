import Foundation

struct EpisodeTranscriptionPlan: Equatable {
    var runEngine: EpisodeTranscriptionEngine
    var modelIdentity: EpisodeTranscriptionModelIdentity
    /// Recorded on the document.
    var languageCode: String
    /// Handed to the engine; differs from `languageCode` only on the English-only Whisper tiny
    /// fallback for a non-English podcast.
    var runLanguageCode: String
    /// Set only by a DEBUG engine override: a completed transcript then counts only when its model
    /// identity matches exactly.
    var isEngineStrict: Bool

    var requiresInstalledWhisperModel: Bool {
        runEngine == .whisper
    }
}

import Foundation

/// A resolved decision for one transcription run, shared by the Ad-Free Pass
/// and the episode transcript panel.
struct EpisodeTranscriptionPlan: Equatable {
    var runEngine: EpisodeTranscriptionEngine
    var modelIdentity: EpisodeTranscriptionModelIdentity
    /// Honest language recorded on the persisted document (per-podcast).
    var languageCode: String
    /// Language handed to the engine; diverges from `languageCode` only on
    /// the English-only whisper tiny fallback for non-English podcasts.
    var runLanguageCode: String
    /// True only for explicit DEBUG engine overrides: completed transcripts
    /// then match by exact model identity instead of counting any completed
    /// transcript as done (decision 3).
    var isEngineStrict: Bool

    var requiresInstalledWhisperModel: Bool {
        runEngine == .whisper
    }
}

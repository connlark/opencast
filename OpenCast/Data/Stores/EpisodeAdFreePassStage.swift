import OpenCastTranscription

enum EpisodeAdFreePassStage: Equatable {
    case idle
    case awaitingModelDownloadConsent(byteCount: Int64)
    case downloadingEpisode
    case installingModel(OpenCastWhisperModelInstallProgress)
    case installingSpeechAssets(fractionCompleted: Double)
    case transcribing(EpisodeTranscriptionProgress)
    case analyzing
    // Cloud detect passes: the job is on the server, no local compute runs
    // and the background session is never armed.
    case cloudQueued
    case cloudTranscribing(RemoteTranscriptionActiveProgress?)
    case cloudDetectingAds
    /// Cloud detection can't run right now (no credits, service off); the
    /// surface offers a one-tap on-device detect instead — never a silent
    /// switch.
    case cloudUnavailable(message: String)
    case completed(zoneCount: Int)
    case interrupted
    case failed(message: String)
    case unavailable(String)
}

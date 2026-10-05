import OpenCastTranscription

enum EpisodeAdFreePassStage: Equatable {
    case idle
    case awaitingModelDownloadConsent(byteCount: Int64)
    case downloadingEpisode
    case installingModel(OpenCastWhisperModelInstallProgress)
    case installingSpeechAssets(fractionCompleted: Double)
    case transcribing(EpisodeTranscriptionProgress)
    case analyzing
    // Cloud detect passes: the job is on the server and no local compute
    // runs; a manual start may still hold the continued-processing card.
    // Queued, verifying, uploading and waiting for credits are the
    // preparation before server transcription starts.
    case cloudQueued
    case cloudVerifying
    /// The server needs this device's copy of the audio. A zero total means
    /// the part count isn't known yet.
    case cloudUploadingExactCopy(completedParts: Int, totalParts: Int)
    case cloudWaitingForCredits
    case cloudTranscribing(RemoteTranscriptionActiveProgress?)
    case cloudDetectingAds
    /// Cloud detection can't run right now (no credits, service off); the
    /// surface offers a one-tap on-device detect instead — never a silent
    /// switch.
    case cloudUnavailable(message: String)
    /// The cloud job keeps running on the server while local polling has
    /// stopped (expiration, connection loss, a local request failure).
    /// Never the on-device `interrupted` copy.
    case cloudParked(RemoteTranscriptionJobExit)
    case completed(zoneCount: Int)
    case interrupted
    case failed(message: String)
    case unavailable(String)
}

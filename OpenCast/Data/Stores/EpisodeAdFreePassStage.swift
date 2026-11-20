import OpenCastTranscription

enum EpisodeAdFreePassStage: Equatable {
    case idle
    case awaitingModelDownloadConsent(byteCount: Int64)
    case downloadingEpisode
    case installingModel(OpenCastWhisperModelInstallProgress)
    case installingSpeechAssets(fractionCompleted: Double)
    case transcribing(EpisodeTranscriptionProgress)
    /// `nil` steps until the run's route is known.
    case analyzing(steps: EpisodeAdFreePassAnalysisSteps?)
    // Cloud stages: the job is on the server and no local compute runs.
    case cloudQueued
    case cloudVerifying
    /// A zero total means the part count isn't known yet.
    case cloudUploadingExactCopy(completedParts: Int, totalParts: Int)
    case cloudWaitingForCredits
    case cloudTranscribing(RemoteTranscriptionActiveProgress?)
    case cloudFinishing
    case cloudUnavailable(message: String)
    /// The server job may still run while local polling has stopped; never shows the on-device
    /// interrupted copy.
    case cloudParked(RemoteTranscriptionJobExit)
    case completed(zoneCount: Int)
    case interrupted
    case failed(message: String)
    case unavailable(String)
}

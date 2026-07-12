import OpenCastTranscription

enum EpisodeAdFreePassStage: Equatable {
    case idle
    case awaitingModelDownloadConsent(byteCount: Int64)
    case downloadingEpisode
    case installingModel(OpenCastWhisperModelInstallProgress)
    case installingSpeechAssets(fractionCompleted: Double)
    case transcribing(EpisodeTranscriptionProgress)
    case analyzing
    case completed(zoneCount: Int)
    case interrupted
    case failed(message: String)
    case unavailable(String)
}

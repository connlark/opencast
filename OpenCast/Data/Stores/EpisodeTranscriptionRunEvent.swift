import OpenCastTranscription

enum EpisodeTranscriptionRunEvent: Sendable, Equatable {
    case progress(EpisodeTranscriptionProgress)
    case checkpoint(OpenCastLongFormTranscriptionCheckpoint)
    case finished(OpenCastTranscriptionResult)
}

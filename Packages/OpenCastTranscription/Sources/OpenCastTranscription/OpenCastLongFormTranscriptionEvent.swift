public enum OpenCastLongFormTranscriptionEvent: Sendable, Equatable {
    case progress(OpenCastLongFormTranscriptionProgress)
    case checkpoint(OpenCastLongFormTranscriptionCheckpoint)
    case finished(OpenCastTranscriptionResult)
}

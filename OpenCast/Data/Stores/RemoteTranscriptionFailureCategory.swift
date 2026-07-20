import OpenCastTranscription

/// Category-level classification of how a remote transcription request ends
/// without a transcript. Stable wire error codes and client-side transport
/// shapes map to fixed user copy here — raw server strings never render.
/// Built for the dev-flag flow, but shaped by the wire schema so the
/// purchase pass reuses it verbatim.
nonisolated enum RemoteTranscriptionFailureCategory: Equatable {
    /// The server ended the job with a stable wire error code.
    case serverRejected(OpenCastRemoteTranscriptionErrorCode)
    /// The backend could not be reached: transport failure, timeout, or an
    /// unclassifiable client-side error.
    case serviceUnavailable
    /// The explicit local download the flow relies on never completed.
    case downloadFailed
    /// The delivered result failed client-side validation.
    case resultInvalid
    /// The episode carries no audio URL to transcribe.
    case missingAudio

    var message: String {
        switch self {
        case let .serverRejected(code):
            switch code {
            case .insufficientCredits:
                "There isn't enough transcription time left."
            case .rateLimited:
                "The transcription service is busy right now."
            case .deadlineExpired:
                "The server gave up waiting and ended the job."
            case .sourceMismatch:
                "The server's audio didn't match this device's copy."
            case .unsupportedMediaType:
                "This episode's audio format isn't supported for remote transcription."
            case .durationTooLong:
                "This episode is longer than remote transcription currently supports."
            case .sourceTooLarge:
                "This episode's audio file is larger than remote transcription currently supports."
            case .originFetchFailed:
                "The server couldn't download this episode's audio."
            case .uploadUnavailable:
                "The transcription service can't accept uploads right now."
            case .uploadIdentityMismatch:
                "The uploaded audio didn't verify as this device's copy."
            default:
                "The server couldn't transcribe this episode."
            }
        case .serviceUnavailable:
            "Couldn't reach the transcription service."
        case .downloadFailed:
            "The episode download didn't finish."
        case .resultInvalid:
            "The server's transcript failed verification on this device."
        case .missingAudio:
            "This episode has no audio to transcribe."
        }
    }
}

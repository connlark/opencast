import OpenCastTranscription

/// Category-level classification of how a remote transcription request ends
/// without a transcript. Stable wire error codes and client-side transport
/// shapes map to fixed user copy here — raw server strings never render.
/// Built for the dev-flag flow, but shaped by the wire schema so the
/// purchase pass reuses it verbatim.
nonisolated enum RemoteTranscriptionFailureCategory: Equatable {
    /// The server ended the job with a stable wire error code.
    case serverRejected(OpenCastRemoteTranscriptionErrorCode)
    /// The backend could not be reached before any create attempt was
    /// marked, or an unclassifiable client-side error ended the request.
    case serviceUnavailable
    /// Transport gave up after the job was attached; the server keeps
    /// working and Resume re-attaches to the same job.
    case connectionLost
    /// A local request leg (App Attest, keychain, decode) gave up; Try Again
    /// re-runs against the same job.
    case localRequestFailed
    /// The explicit local download the flow relies on never completed.
    case downloadFailed
    /// The delivered result failed client-side validation.
    case resultInvalid
    /// The server finished and deleted its result, but no transcript with
    /// that job's provenance exists on this device.
    case acknowledgedWithoutLocalImport
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
        case .connectionLost:
            "Lost the connection while the server was still working on this transcript."
        case .localRequestFailed:
            "This device couldn't complete a request to the transcription service."
        case .downloadFailed:
            "The episode download didn't finish."
        case .resultInvalid:
            "The server's transcript failed verification on this device."
        case .acknowledgedWithoutLocalImport:
            "The server finished, but the transcript wasn't saved on this device."
        case .missingAudio:
            "This episode has no audio to transcribe."
        }
    }

    /// Whether Try Again is honest for this outcome: the same reference (or
    /// a fresh one, once the server result is gone) can be run again without
    /// paying for a second job.
    var offersRetry: Bool {
        switch self {
        case .serviceUnavailable, .localRequestFailed, .downloadFailed, .acknowledgedWithoutLocalImport:
            true
        case .serverRejected(let code):
            code == .rateLimited || code == .internalError
        case .connectionLost, .resultInvalid, .missingAudio:
            false
        }
    }
}

import OpenCastTranscription

/// Typed failures thrown by `RemoteTranscriptionJobRunner`. Cancellation is
/// not represented here — `CancellationError` passes through unchanged.
nonisolated enum RemoteTranscriptionJobRunError: Error, Equatable {
    case downloadFailed
    case serverRejected(OpenCastRemoteTranscriptionErrorCode)
    /// The server cancelled the job (deadline or explicit remote cancel).
    case remoteCancelled
    /// The server proved it fetched different bytes and the exact-copy
    /// upload could not resolve it; on-device transcription is the way
    /// forward.
    case mismatchLocalFallback
    case resultInvalid
    case serviceUnavailable

    var failureCategory: RemoteTranscriptionFailureCategory {
        switch self {
        case .downloadFailed: .downloadFailed
        case .serverRejected(let code): .serverRejected(code)
        case .remoteCancelled, .mismatchLocalFallback: .serviceUnavailable
        case .resultInvalid: .resultInvalid
        case .serviceUnavailable: .serviceUnavailable
        }
    }
}

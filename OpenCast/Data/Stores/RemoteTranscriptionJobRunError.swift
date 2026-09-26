import OpenCastTranscription

/// Typed failures thrown by `RemoteTranscriptionJobRunner`. Cancellation is
/// not represented here — `CancellationError` passes through unchanged and
/// never cancels the server job.
nonisolated enum RemoteTranscriptionJobRunError: Error, Equatable {
    /// The explicit episode download never completed; the reference is kept
    /// with a `downloadFailed` exit.
    case downloadFailed
    case serverRejected(OpenCastRemoteTranscriptionErrorCode)
    /// The server cancelled the job (deadline or explicit remote cancel).
    case remoteCancelled
    /// The server proved it fetched different bytes and the exact-copy
    /// upload could not resolve it; on-device transcription is the way
    /// forward.
    case mismatchLocalFallback
    case resultInvalid
    /// The backend could not be reached before any create attempt was
    /// marked; the prepared reference is reused by Try Again.
    case serviceUnavailable
    /// Transport gave up after the job was attached (or after a create may
    /// have reached the server). The reference stays attached to the same
    /// job; Resume polls it again.
    case connectionLost
    /// A local request leg (App Attest, keychain, decode) gave up. The
    /// reference stays attached to the same job; Try Again re-runs it.
    case localRequestFailed
    /// The server reports the result as acknowledged but no transcript with
    /// that job's provenance exists on this device. The server result is
    /// already deleted, so the reference is cleared and the diagnostic
    /// event is the preserved evidence.
    case acknowledgedWithoutLocalImport

    var failureCategory: RemoteTranscriptionFailureCategory {
        switch self {
        case .downloadFailed: .downloadFailed
        case .serverRejected(let code): .serverRejected(code)
        case .remoteCancelled, .mismatchLocalFallback: .serviceUnavailable
        case .resultInvalid: .resultInvalid
        case .serviceUnavailable: .serviceUnavailable
        case .connectionLost: .connectionLost
        case .localRequestFailed: .localRequestFailed
        case .acknowledgedWithoutLocalImport: .acknowledgedWithoutLocalImport
        }
    }
}

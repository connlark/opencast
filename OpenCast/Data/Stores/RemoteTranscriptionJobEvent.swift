nonisolated enum RemoteTranscriptionJobEvent: Equatable {
    /// Device download and server origin fetch are running concurrently.
    case downloading
    case verifying
    /// The job is created and waiting server-side (staging, hash match).
    case queuedRemotely
    case waitingForCredits
    case processing(RemoteTranscriptionActiveProgress)
    /// Only a detect job an earlier build created still asks for this.
    case detectingAds
    case uploadingExactCopy(completedParts: Int, totalParts: Int)
    case saving
}

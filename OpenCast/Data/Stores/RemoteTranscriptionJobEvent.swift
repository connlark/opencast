/// Progress events emitted by `RemoteTranscriptionJobRunner` while a job
/// runs. The plain Transcribe Remotely surface maps these onto
/// `RemoteTranscriptionRequestPhase`; the cloud detect-ads pass maps them
/// onto its queue stages.
nonisolated enum RemoteTranscriptionJobEvent: Equatable {
    /// Device download and server origin fetch are running concurrently.
    case downloading
    case verifying
    /// The job is created and waiting server-side (staging, hash match).
    case queuedRemotely
    case waitingForCredits
    case processing(RemoteTranscriptionActiveProgress)
    /// Chained server-side ad detection after stitching (detect jobs only).
    case detectingAds
    case uploadingExactCopy(completedParts: Int, totalParts: Int)
    case saving
}

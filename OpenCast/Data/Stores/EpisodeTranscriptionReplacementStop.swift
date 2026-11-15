/// How a replacement transcription
/// (`PriorCompletedTranscriptPolicy.preserveKeepingInterruptedPartial`)
/// stopped short. The prior transcript was restored either way, so the
/// record reads completed, and this in-memory note is the only sign of the
/// stop.
nonisolated enum EpisodeTranscriptionReplacementStop: Equatable, Sendable {
    case interrupted(EpisodeTranscriptionReplacementInterruption)
    /// Cancelled, not interrupted: the stop that leaves a first
    /// transcription `.cancelled`.
    case cancelled
}

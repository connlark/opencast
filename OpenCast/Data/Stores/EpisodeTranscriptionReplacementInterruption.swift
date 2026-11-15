/// An interrupted replacement transcription
/// (`PriorCompletedTranscriptPolicy.preserveKeepingInterruptedPartial`):
/// the prior transcript was restored, so the record reads completed, and
/// this in-memory note is the only sign that the replacement is unfinished.
nonisolated struct EpisodeTranscriptionReplacementInterruption: Equatable, Sendable {
    /// An environmental compute or storage failure, rather than a lifecycle
    /// interruption (backgrounding, session expiry).
    let isEnvironmental: Bool
}

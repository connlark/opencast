/// What a transcription run does with the episode's completed transcript,
/// which it overwrites in place (one record per episode) from its first
/// write until it completes.
nonisolated enum PriorCompletedTranscriptPolicy: Equatable, Sendable {
    /// The run replaces the prior transcript outright; a stop leaves the
    /// run's own cancelled, interrupted or failed record.
    case discard
    /// Every stop before completion restores the prior transcript and
    /// deletes the run's partial (Improve Transcript).
    case preserve
    /// As `.preserve` for a user cancel and a hard failure. A lifecycle or
    /// environmental interruption also restores the prior transcript, but a
    /// Whisper run keeps its partial on disk, so the next run over the same
    /// bytes, model and language resumes from its last checkpoint, and the
    /// store notes the interruption for
    /// `EpisodeTranscriptionStore.interruptedReplacement(for:)` (the restored
    /// record reads completed, so nothing else shows the run is unfinished).
    case preserveKeepingInterruptedPartial
}

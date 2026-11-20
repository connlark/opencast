/// The prior transcript was restored and the record reads completed; this in-memory note is the
/// only sign that the replacement is unfinished.
nonisolated struct EpisodeTranscriptionReplacementInterruption: Equatable, Sendable {
    /// A compute or storage failure rather than a lifecycle interruption.
    let isEnvironmental: Bool
}

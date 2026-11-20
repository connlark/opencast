/// The prior transcript was restored either way; this in-memory note is the only sign of the stop.
nonisolated enum EpisodeTranscriptionReplacementStop: Equatable, Sendable {
    case interrupted(EpisodeTranscriptionReplacementInterruption)
    case cancelled
}

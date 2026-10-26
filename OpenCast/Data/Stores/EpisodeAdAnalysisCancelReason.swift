/// Why the active device ad-detection run stopped early.
enum EpisodeAdAnalysisCancelReason: Sendable, Hashable {
    /// The listener stopped it. The run record ends cancelled; nothing
    /// resumes it.
    case listener
    /// Its continued-processing card expired. The run record stays
    /// resumable with the replies it kept.
    case expiration
    /// The listener removed the run's key in AI Services. The run ends at
    /// once as needing a key, as when a send finds the key gone: the
    /// episode's record fails with that kind, the run record fails, and no
    /// key screen opens.
    case keyRemoved
}

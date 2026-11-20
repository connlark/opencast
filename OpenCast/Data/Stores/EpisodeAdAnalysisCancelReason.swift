enum EpisodeAdAnalysisCancelReason: Sendable, Hashable {
    /// The run record ends cancelled and never resumes.
    case listener
    /// The run record stays resumable with the replies it kept.
    case expiration
    /// The run fails as needing a key, and no key screen opens.
    case keyRemoved
}

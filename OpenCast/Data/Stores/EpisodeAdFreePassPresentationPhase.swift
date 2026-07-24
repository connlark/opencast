nonisolated enum EpisodeAdFreePassPresentationPhase: Equatable, Sendable {
    case idle
    case queued
    case deferred
    case checking
    case running
    case completed
    case failed
    case unavailable
}

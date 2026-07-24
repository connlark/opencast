enum AdFreePassQueueEpisodeStatus: Equatable {
    case notQueued
    case queued(ahead: Int)
    case running
    case completed(zoneCount: Int)
    case failed(message: String)
    /// A cloud detect pass could not run (no credits, service off); the
    /// surfaces offer a one-tap on-device detect instead.
    case cloudUnavailable(message: String)
    case capDeferred
}

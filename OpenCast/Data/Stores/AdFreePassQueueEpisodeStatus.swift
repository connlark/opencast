enum AdFreePassQueueEpisodeStatus: Equatable {
    case notQueued
    case queued(ahead: Int)
    case running
    case completed(zoneCount: Int)
    case failed(message: String)
    case capDeferred
}

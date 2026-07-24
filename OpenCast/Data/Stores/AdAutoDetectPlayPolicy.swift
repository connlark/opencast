/// Decision-11 qualification for play-triggered auto ad detection: playing
/// an episode of an auto-detect-enabled show enqueues an `.auto` pass iff
/// the episode has no current completed analysis and is not already in the
/// queue. Pure so the table is unit-testable.
struct AdAutoDetectPlayPolicy {
    let isAutoDetectEnabled: Bool
    let hasCurrentCompletedAnalysis: Bool
    let queueStatus: AdFreePassQueueEpisodeStatus

    var shouldEnqueue: Bool {
        guard isAutoDetectEnabled, !hasCurrentCompletedAnalysis else {
            return false
        }

        switch queueStatus {
        case .notQueued, .failed, .cloudUnavailable:
            // `.cloudUnavailable` re-qualifies like `.failed`: credits
            // arriving later self-heal the next play.
            return true
        case .queued, .running, .completed, .capDeferred:
            return false
        }
    }
}

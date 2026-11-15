/// Decision-11 qualification for play-triggered auto ad detection: playing
/// an episode of an auto-detect-enabled show enqueues an `.auto` pass iff
/// the episode has no current completed analysis attached to its trusted
/// download and is not already in the queue. Pure so the table is
/// unit-testable.
struct AdAutoDetectPlayPolicy {
    let isAutoDetectEnabled: Bool
    let hasCurrentCompletedAnalysis: Bool
    let isAnalysisAttached: Bool
    let queueStatus: AdFreePassQueueEpisodeStatus

    var isReplaySuppressed = false

    /// The statuses a play reaches the policy with. A pass that failed this
    /// session is not retried on play, whatever waiting might cure: the
    /// listener retries it by hand.
    static func admitsPlay(with queueStatus: AdFreePassQueueEpisodeStatus) -> Bool {
        switch queueStatus {
        case .notQueued, .completed:
            true
        case .queued, .running, .remoteParked, .failed, .cloudUnavailable, .keyRequired:
            false
        }
    }

    var shouldEnqueue: Bool {
        guard isAutoDetectEnabled,
              !(hasCurrentCompletedAnalysis && isAnalysisAttached),
              !isReplaySuppressed
        else {
            return false
        }

        switch queueStatus {
        case .notQueued, .completed, .failed, .cloudUnavailable:
            // A retained outcome is history: a completed pass whose download
            // has since gone is a never-scanned episode again.
            // `.cloudUnavailable` re-qualifies like `.failed`: credits
            // arriving later self-heal the next play.
            return true
        case .queued, .running, .remoteParked:
            return false
        case .keyRequired:
            // Playing it again would only ask for the same key again.
            return false
        }
    }
}

struct AdAutoDetectPlayPolicy {
    let isAutoDetectEnabled: Bool
    let hasCurrentCompletedAnalysis: Bool
    let isAnalysisAttached: Bool
    let queueStatus: AdFreePassQueueEpisodeStatus

    var isReplaySuppressed = false

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
        return Self.admitsPlay(with: queueStatus)
    }
}

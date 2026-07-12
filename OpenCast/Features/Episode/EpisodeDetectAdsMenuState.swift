/// Label/enabled mapping for the shared context menu's Detect Ads action.
enum EpisodeDetectAdsMenuState: Equatable {
    case detect
    case detecting
    case queued
    case detected

    init(
        queueStatus: AdFreePassQueueEpisodeStatus,
        hasCurrentCompletedAnalysis: Bool
    ) {
        switch queueStatus {
        case .running:
            self = .detecting
        case .queued, .capDeferred:
            self = .queued
        case .completed:
            self = .detected
        case .failed, .notQueued:
            self = hasCurrentCompletedAnalysis ? .detected : .detect
        }
    }

    var title: String {
        switch self {
        case .detect:
            "Detect Ads"
        case .detecting:
            "Detecting…"
        case .queued:
            "Queued"
        case .detected:
            "Ads Detected"
        }
    }

    var isEnabled: Bool {
        self == .detect
    }
}

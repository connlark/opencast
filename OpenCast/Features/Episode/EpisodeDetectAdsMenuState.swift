enum EpisodeDetectAdsMenuState: Equatable {
    case detect
    case detecting
    case queued
    case detected
    /// A current analysis whose trusted download is gone, so its skips cannot install.
    case detectAgain

    /// A retained session outcome is history, not work in flight, so it decides like `.notQueued`.
    /// Attachment costs a file stat, so it is read only for a current analysis.
    init(
        queueStatus: AdFreePassQueueEpisodeStatus,
        hasCurrentCompletedAnalysis: Bool,
        isAnalysisAttached: @autoclosure () -> Bool
    ) {
        switch queueStatus {
        case .running:
            self = .detecting
        case .queued, .remoteParked:
            self = .queued
        case .completed, .failed, .cloudUnavailable, .keyRequired, .notQueued:
            if !hasCurrentCompletedAnalysis {
                self = .detect
            } else {
                self = isAnalysisAttached() ? .detected : .detectAgain
            }
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
        case .detectAgain:
            "Detect Ads Again"
        }
    }

    var isEnabled: Bool {
        self == .detect || self == .detectAgain
    }

    var offersDetectAgain: Bool {
        self == .detectAgain
    }

    /// Never for a current analysis, attached or not: an analysis-only run could only repeat it.
    var enablesAnalysisOnly: Bool {
        self == .detect
    }
}

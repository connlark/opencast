/// Label/enabled mapping for the shared context menu's Detect Ads action.
enum EpisodeDetectAdsMenuState: Equatable {
    case detect
    case detecting
    case queued
    case detected
    /// A current analysis whose trusted download is gone: its skips cannot
    /// install until a pass makes the download and transcript match again.
    case detectAgain

    /// A retained session outcome is history, not work in flight, so it is
    /// decided like `.notQueued`. Attachment costs a file stat, so it is
    /// read only once the analysis is known to be current.
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

    /// Episode Actions offers the full pass by name only when it restores
    /// skips the page says are unavailable.
    var offersDetectAgain: Bool {
        self == .detectAgain
    }

    /// An analysis-only run over the existing transcript: never for a
    /// current analysis, attached or not, which it could only repeat.
    var enablesAnalysisOnly: Bool {
        self == .detect
    }
}

import OpenCastPlayback

struct AdFreePassUnattendedWorkPolicy {
    var isAnySceneActive: Bool
    var isCardArmed: Bool
    var playbackState: PlaybackState
    var isLowPowerModeEnabled: Bool

    /// States in which the audio session keeps the app running. A `.loading`
    /// item may never have been asked to play.
    static func isLive(_ state: PlaybackState) -> Bool {
        switch state {
        case .playing, .buffering:
            true
        case .idle, .loading, .paused, .failed:
            false
        }
    }

    var isPlaybackSustainingWork: Bool {
        Self.isLive(playbackState) && !isLowPowerModeEnabled
    }

    var allowsUnattendedWork: Bool {
        isAnySceneActive || isCardArmed || isPlaybackSustainingWork
    }

    /// A hold waits out the inactive grace: an Up Next advance passes through
    /// `.paused` and `.loading` before `.playing`, and a stall must not stop work.
    var playbackChangeAction: AdFreePassPlaybackChangeAction {
        guard !isAnySceneActive else {
            return .none
        }
        return allowsUnattendedWork ? .resumeLifecycleHold : .holdIfStillIneligible
    }
}

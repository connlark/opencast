import OpenCastPlayback

/// When the ad-detection queue may run an item nobody tapped (one a play or
/// a new download queued): while someone can see the app, under the armed
/// continued-processing card, or while playback keeps the app running and
/// the listener has not asked the phone to save power.
struct AdFreePassUnattendedWorkPolicy {
    var isAnySceneActive: Bool
    var isCardArmed: Bool
    var playbackState: PlaybackState
    var isLowPowerModeEnabled: Bool

    /// The states in which the audio session keeps the app running. A
    /// `.loading` item may never have been asked to play.
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

    /// What a change of playback state asks of the queue. Only a change
    /// while no scene is active matters: a scene's own lifecycle covers the
    /// rest. Then it follows the rule: while the rule allows work a held
    /// queue resumes (with no lifecycle hold, nothing happens), so an armed
    /// card with playback paused reads as a resume too. Otherwise, live
    /// playback in Low Power Mode included, a hold waits out the inactive
    /// grace and is taken again on what is true then, so an Up Next advance
    /// (`.paused`, `.loading`, then `.playing`) or a short stall never stops
    /// work.
    var playbackChangeAction: AdFreePassPlaybackChangeAction {
        guard !isAnySceneActive else {
            return .none
        }
        return allowsUnattendedWork ? .resumeLifecycleHold : .holdIfStillIneligible
    }
}

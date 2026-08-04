enum PlaybackInterruptionResumePolicy {
    static func shouldRecordResumeIntent(
        isPlaybackRequested: Bool,
        state: PlaybackState
    ) -> Bool {
        isPlaybackRequested && (state == .playing || state == .buffering || state == .loading)
    }

    static func shouldResume(
        operatingSystemShouldResume: Bool,
        recordedResumeIntent: Bool,
        hasCurrentEpisode: Bool
    ) -> Bool {
        operatingSystemShouldResume && recordedResumeIntent && hasCurrentEpisode
    }
}

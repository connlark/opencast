import Testing
@testable import OpenCastPlayback

@MainActor
@Suite
struct PlaybackInterruptionResumePolicyTests {
    @Test(
        arguments: [true, false],
        [PlaybackState.idle, .loading, .buffering, .paused, .playing, .failed("failed")]
    )
    func resumeIntentRequiresBothARequestAndAPlayingState(
        isPlaybackRequested: Bool,
        state: PlaybackState
    ) {
        let expected = isPlaybackRequested && state.showsPauseButton

        #expect(PlaybackInterruptionResumePolicy.shouldRecordResumeIntent(
            isPlaybackRequested: isPlaybackRequested,
            state: state
        ) == expected)
    }

    @Test
    func resumeRequiresOperatingSystemIntentRecordedIntentAndAnEpisode() {
        for operatingSystemShouldResume in [true, false] {
            for recordedResumeIntent in [true, false] {
                for hasCurrentEpisode in [true, false] {
                    #expect(PlaybackInterruptionResumePolicy.shouldResume(
                        operatingSystemShouldResume: operatingSystemShouldResume,
                        recordedResumeIntent: recordedResumeIntent,
                        hasCurrentEpisode: hasCurrentEpisode
                    ) == (operatingSystemShouldResume && recordedResumeIntent && hasCurrentEpisode))
                }
            }
        }
    }
}

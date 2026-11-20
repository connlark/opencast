import Testing
@testable import OpenCastPlayback

@MainActor
@Suite
struct PlaybackInterruptionResumePolicyTests {
    @Test(
        "An interruption records resume intent only while playback is requested and under way",
        arguments: [
            (true, PlaybackState.failed("failed"), false),
            (true, PlaybackState.idle, false),
            (false, PlaybackState.playing, false),
            (true, PlaybackState.playing, true)
        ]
    )
    func resumeIntentRequiresBothARequestAndAPlayingState(
        isPlaybackRequested: Bool,
        state: PlaybackState,
        records: Bool
    ) {
        #expect(PlaybackInterruptionResumePolicy.shouldRecordResumeIntent(
            isPlaybackRequested: isPlaybackRequested,
            state: state
        ) == records)
    }

    @Test(
        "An interruption's end resumes only when the system asks, intent was recorded and an episode is loaded",
        arguments: [
            (true, true, false, false),
            (false, true, true, false),
            (true, false, true, false),
            (true, true, true, true)
        ]
    )
    func resumeRequiresOperatingSystemIntentRecordedIntentAndAnEpisode(
        operatingSystemShouldResume: Bool,
        recordedResumeIntent: Bool,
        hasCurrentEpisode: Bool,
        resumes: Bool
    ) {
        #expect(PlaybackInterruptionResumePolicy.shouldResume(
            operatingSystemShouldResume: operatingSystemShouldResume,
            recordedResumeIntent: recordedResumeIntent,
            hasCurrentEpisode: hasCurrentEpisode
        ) == resumes)
    }
}

import OpenCastPlayback
import Testing
@testable import OpenCast

@MainActor
@Suite("Ad-free pass unattended work policy")
struct AdFreePassUnattendedWorkPolicyTests {
    @Test(
        "Unattended work runs with a scene active, the card armed, or live playback with Low Power Mode off",
        arguments: [
            (true, false, PlaybackState.paused, true, true, AdFreePassPlaybackChangeAction.none),
            (false, true, .paused, true, true, .resumeLifecycleHold),
            (false, false, .playing, false, true, .resumeLifecycleHold),
            (false, false, .buffering, false, true, .resumeLifecycleHold),
            (false, false, .playing, true, false, .holdIfStillIneligible),
            (false, false, .paused, false, false, .holdIfStillIneligible),
            (false, false, .loading, false, false, .holdIfStillIneligible),
            (false, false, .idle, false, false, .holdIfStillIneligible),
            (false, false, .failed("stalled"), false, false, .holdIfStillIneligible),
        ]
    )
    func ruleTable(
        isAnySceneActive: Bool,
        isCardArmed: Bool,
        playbackState: PlaybackState,
        isLowPowerModeEnabled: Bool,
        allowsWork: Bool,
        action: AdFreePassPlaybackChangeAction
    ) {
        let policy = AdFreePassUnattendedWorkPolicy(
            isAnySceneActive: isAnySceneActive,
            isCardArmed: isCardArmed,
            playbackState: playbackState,
            isLowPowerModeEnabled: isLowPowerModeEnabled
        )

        #expect(policy.allowsUnattendedWork == allowsWork)
        #expect(policy.playbackChangeAction == action)
    }
}

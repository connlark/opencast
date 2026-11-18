import OpenCastPlayback
import Testing
@testable import OpenCast

@MainActor
@Suite("Ad-free pass unattended work policy")
struct AdFreePassUnattendedWorkPolicyTests {
    /// Every playback state, with whether it keeps the app running.
    private static let states: [(state: PlaybackState, isLive: Bool)] = [
        (.idle, false),
        (.loading, false),
        (.buffering, true),
        (.paused, false),
        (.playing, true),
        (.failed("stalled"), false),
    ]

    @Test("Unattended work runs with a scene active, the card armed, or live playback with Low Power Mode off")
    func ruleTable() {
        var rows = 0
        for isAnySceneActive in [false, true] {
            for isCardArmed in [false, true] {
                for (state, isLive) in Self.states {
                    for isLowPowerModeEnabled in [false, true] {
                        let policy = AdFreePassUnattendedWorkPolicy(
                            isAnySceneActive: isAnySceneActive,
                            isCardArmed: isCardArmed,
                            playbackState: state,
                            isLowPowerModeEnabled: isLowPowerModeEnabled
                        )
                        let expected = isAnySceneActive || isCardArmed || (isLive && !isLowPowerModeEnabled)
                        #expect(
                            policy.allowsUnattendedWork == expected,
                            "scene \(isAnySceneActive) card \(isCardArmed) \(state) lowPower \(isLowPowerModeEnabled)"
                        )
                        #expect(policy.isPlaybackSustainingWork == (isLive && !isLowPowerModeEnabled))
                        rows += 1
                    }
                }
            }
        }
        #expect(rows == 48)
    }

    @Test("Only playing and buffering are live")
    func liveStates() {
        for (state, isLive) in Self.states {
            #expect(AdFreePassUnattendedWorkPolicy.isLive(state) == isLive, "\(state)")
        }
    }

    @Test("A playback change asks nothing while any scene is active")
    func sceneActiveAsksNothing() {
        for (state, _) in Self.states {
            for isLowPowerModeEnabled in [false, true] {
                #expect(policy(state, scene: true, lowPower: isLowPowerModeEnabled).playbackChangeAction == .none)
            }
        }
    }

    @Test("With no scene active, a playback change resumes a hold while the rule allows work and holds otherwise")
    func backgroundPlaybackChangeActions() {
        for (state, isLive) in Self.states {
            for isCardArmed in [false, true] {
                for isLowPowerModeEnabled in [false, true] {
                    let allows = isCardArmed || (isLive && !isLowPowerModeEnabled)
                    #expect(
                        policy(state, card: isCardArmed, lowPower: isLowPowerModeEnabled).playbackChangeAction
                            == (allows ? .resumeLifecycleHold : .holdIfStillIneligible),
                        "\(state) card \(isCardArmed) lowPower \(isLowPowerModeEnabled)"
                    )
                }
            }
        }
        #expect(policy(.playing).playbackChangeAction == .resumeLifecycleHold)
        #expect(policy(.buffering).playbackChangeAction == .resumeLifecycleHold)
        // Live again after the grace, but in Low Power Mode: the rule says
        // no, so the hold is still taken.
        #expect(policy(.playing, lowPower: true).playbackChangeAction == .holdIfStillIneligible)
        // An armed card with playback paused reads as a resume, which does
        // nothing without a lifecycle hold.
        #expect(policy(.paused, card: true).playbackChangeAction == .resumeLifecycleHold)
    }

    @Test("The re-read after the grace saves an Up Next advance and holds a real stop")
    func reReadSavesAnAdvance() {
        // The advance publishes .paused, then .loading in the same turn,
        // then .playing once the next episode starts.
        #expect(policy(.paused).playbackChangeAction == .holdIfStillIneligible)
        #expect(policy(.loading).playbackChangeAction == .holdIfStillIneligible)
        #expect(policy(.playing).playbackChangeAction != .holdIfStillIneligible)
        // A stall that recovers.
        #expect(policy(.buffering).playbackChangeAction != .holdIfStillIneligible)
        // A real stop still reads stopped after the grace.
        #expect(policy(.paused).playbackChangeAction == .holdIfStillIneligible)
        // Playing on in Low Power Mode is not a reason to run.
        #expect(!policy(.playing, lowPower: true).allowsUnattendedWork)
    }

    private func policy(
        _ state: PlaybackState,
        scene: Bool = false,
        card: Bool = false,
        lowPower: Bool = false
    ) -> AdFreePassUnattendedWorkPolicy {
        AdFreePassUnattendedWorkPolicy(
            isAnySceneActive: scene,
            isCardArmed: card,
            playbackState: state,
            isLowPowerModeEnabled: lowPower
        )
    }
}

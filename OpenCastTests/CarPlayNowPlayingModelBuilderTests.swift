import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("CarPlay now playing model builder")
struct CarPlayNowPlayingModelBuilderTests {
    @Test("Voice Boost reports its state in every mode but only toggles per-episode")
    func voiceBoostEnablement() {
        let perEpisode = makeState(isVoiceBoostEnabled: true, canChangeVoiceBoost: true)
        let globalOn = makeState(isVoiceBoostEnabled: true, canChangeVoiceBoost: false)
        let globalOff = makeState(isVoiceBoostEnabled: false, canChangeVoiceBoost: false)

        #expect(perEpisode.isVoiceBoostOn)
        #expect(perEpisode.canToggleVoiceBoost)
        // A global mode still shows the state the car cannot change.
        #expect(globalOn.isVoiceBoostOn)
        #expect(!globalOn.canToggleVoiceBoost)
        #expect(!globalOff.isVoiceBoostOn)
        #expect(!globalOff.canToggleVoiceBoost)
    }

    @Test("Nothing loaded disables the per-episode toggles")
    func nothingLoadedDisablesEpisodeControls() {
        let idle = makeState(
            hasLoadedEpisode: false,
            isCurrentShowSubscribed: true,
            canChangeVoiceBoost: true
        )

        #expect(!idle.hasLoadedEpisode)
        #expect(!idle.canToggleVoiceBoost)
        #expect(!idle.canShowCurrentShow)
    }

    @Test("The album-artist push needs a show that is still subscribed")
    func albumArtistEnablement() {
        let subscribed = makeState(isCurrentShowSubscribed: true)
        let orphaned = makeState(isCurrentShowSubscribed: false)

        #expect(subscribed.canShowCurrentShow)
        #expect(!orphaned.canShowCurrentShow)
    }

    @Test("Identical inputs build equal states so the row is not rebuilt")
    func equalityGating() {
        #expect(makeState() == makeState())
        #expect(makeState(rate: 1) != makeState(rate: 1.25))
        #expect(
            makeState(isVoiceBoostEnabled: true)
                != makeState(isVoiceBoostEnabled: false)
        )
    }

    private func makeState(
        rate: Float = 1,
        hasLoadedEpisode: Bool = true,
        isCurrentShowSubscribed: Bool = true,
        isVoiceBoostEnabled: Bool = false,
        canChangeVoiceBoost: Bool = true
    ) -> CarPlayNowPlayingButtonState {
        CarPlayNowPlayingModelBuilder.buttonState(
            rate: rate,
            hasLoadedEpisode: hasLoadedEpisode,
            isCurrentShowSubscribed: isCurrentShowSubscribed,
            isVoiceBoostEnabled: isVoiceBoostEnabled,
            canChangeVoiceBoost: canChangeVoiceBoost
        )
    }
}

import CoreGraphics
import Testing
@testable import OpenCast

@MainActor
@Suite("Now Playing drag intent")
struct NowPlayingDragIntentTests {
    @Test("Open Sound Lab yields vertical flicks to card dismissal")
    func openSoundLabYieldsVerticalFlicksToCardDismissal() {
        let translation = CGSize(width: 48, height: 72)

        #expect(NowPlayingDragIntent.shouldSoundLabYieldToCardDismiss(translation: translation))
        #expect(NowPlayingDragIntent.shouldStartCardDismiss(
            translation: translation,
            isSoundLabInteractionActive: true
        ))
    }

    @Test("Active Sound Lab keeps horizontal drags for reveal interaction")
    func activeSoundLabKeepsHorizontalDragsForRevealInteraction() {
        let translation = CGSize(width: 72, height: 48)

        #expect(!NowPlayingDragIntent.shouldSoundLabYieldToCardDismiss(translation: translation))
        #expect(!NowPlayingDragIntent.shouldStartCardDismiss(
            translation: translation,
            isSoundLabInteractionActive: true
        ))
    }

    @Test("Closed card keeps existing permissive dismiss angle")
    func closedCardKeepsExistingPermissiveDismissAngle() {
        let translation = CGSize(width: 72, height: 54)

        #expect(NowPlayingDragIntent.shouldStartCardDismiss(
            translation: translation,
            isSoundLabInteractionActive: false
        ))
    }

}

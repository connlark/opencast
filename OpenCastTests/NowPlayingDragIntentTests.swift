import CoreGraphics
import Testing
@testable import OpenCast

@MainActor
@Suite("Now Playing drag intent")
struct NowPlayingDragIntentTests {
    @Test("Open peel yields vertical flicks to card dismissal")
    func openPeelYieldsVerticalFlicksToCardDismissal() {
        let translation = CGSize(width: 48, height: 72)

        #expect(NowPlayingDragIntent.shouldPeelYieldToCardDismiss(translation: translation))
        #expect(NowPlayingDragIntent.shouldStartCardDismiss(
            translation: translation,
            isPeelInteractionActive: true
        ))
    }

    @Test("Active peel keeps horizontal drags for peel interaction")
    func activePeelKeepsHorizontalDragsForPeelInteraction() {
        let translation = CGSize(width: 72, height: 48)

        #expect(!NowPlayingDragIntent.shouldPeelYieldToCardDismiss(translation: translation))
        #expect(!NowPlayingDragIntent.shouldStartCardDismiss(
            translation: translation,
            isPeelInteractionActive: true
        ))
    }

    @Test("Closed card keeps existing permissive dismiss angle")
    func closedCardKeepsExistingPermissiveDismissAngle() {
        let translation = CGSize(width: 72, height: 54)

        #expect(NowPlayingDragIntent.shouldStartCardDismiss(
            translation: translation,
            isPeelInteractionActive: false
        ))
    }
}

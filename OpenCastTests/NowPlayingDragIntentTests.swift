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

    @Test("Mini-player downward vertical drag starts dismissal")
    func miniPlayerDownwardVerticalDragStartsDismissal() {
        let translation = CGSize(width: 10, height: 18)

        #expect(NowPlayingDragIntent.shouldStartMiniPlayerDismiss(translation: translation))
    }

    @Test("Mini-player horizontal drag does not start dismissal")
    func miniPlayerHorizontalDragDoesNotStartDismissal() {
        let translation = CGSize(width: 30, height: 18)

        #expect(!NowPlayingDragIntent.shouldStartMiniPlayerDismiss(translation: translation))
    }

    @Test("Mini-player short downward swipe cancels dismissal")
    func miniPlayerShortDownwardSwipeCancelsDismissal() {
        #expect(!NowPlayingDragIntent.shouldCompleteMiniPlayerDismiss(
            translation: CGSize(width: 4, height: 24),
            predictedEndTranslation: CGSize(width: 6, height: 60)
        ))
    }

    @Test("Mini-player predicted end completes dismissal")
    func miniPlayerPredictedEndCompletesDismissal() {
        #expect(NowPlayingDragIntent.shouldCompleteMiniPlayerDismiss(
            translation: CGSize(width: 4, height: 24),
            predictedEndTranslation: CGSize(width: 8, height: 96)
        ))
    }
}

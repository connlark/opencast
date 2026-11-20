import CoreGraphics
import Testing
@testable import OpenCast

@MainActor
@Suite("Now Playing drag intent")
struct NowPlayingDragIntentTests {
    @Test("Active Sound Lab keeps horizontal drags for reveal interaction")
    func activeSoundLabKeepsHorizontalDragsForRevealInteraction() {
        let translation = CGSize(width: 72, height: 48)

        #expect(!NowPlayingDragIntent.shouldSoundLabYieldToCardDismiss(translation: translation))
        #expect(!NowPlayingDragIntent.shouldStartCardDismiss(
            translation: translation,
            isSoundLabInteractionActive: true
        ))
    }
}

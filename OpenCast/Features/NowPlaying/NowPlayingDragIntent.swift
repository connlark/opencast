import CoreGraphics

enum NowPlayingDragIntent {
    static func shouldStartCardDismiss(
        translation: CGSize,
        isSoundLabInteractionActive: Bool
    ) -> Bool {
        guard translation.height > 0 else {
            return false
        }

        let verticalBias: CGFloat = isSoundLabInteractionActive ? 1 : 0.7
        return translation.height > abs(translation.width) * verticalBias
    }

    static func shouldSoundLabYieldToCardDismiss(translation: CGSize) -> Bool {
        translation.height > 20 && translation.height > abs(translation.width)
    }

    /// A drag that starts in the secondary pane scrolls or reorders the pane;
    /// it never starts the card's dismiss drag.
    static func startsInSecondaryPane(_ location: CGPoint, paneFrames: [CGRect]) -> Bool {
        paneFrames.contains { $0.contains(location) }
    }
}

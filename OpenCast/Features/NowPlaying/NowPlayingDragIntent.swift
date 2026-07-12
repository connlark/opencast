import CoreGraphics

enum NowPlayingDragIntent {
    static func shouldStartCardDismiss(
        translation: CGSize,
        isPeelInteractionActive: Bool
    ) -> Bool {
        guard translation.height > 0 else {
            return false
        }

        let verticalBias: CGFloat = isPeelInteractionActive ? 1 : 0.7
        return translation.height > abs(translation.width) * verticalBias
    }

    static func shouldPeelYieldToCardDismiss(translation: CGSize) -> Bool {
        translation.height > 20 && translation.height > abs(translation.width)
    }
}

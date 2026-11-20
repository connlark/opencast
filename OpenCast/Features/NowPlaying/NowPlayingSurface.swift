import SwiftUI

nonisolated struct NowPlayingSurface: Equatable {
    let windowSize: CGSize
    let safeAreaInsets: EdgeInsets
    let pose: WindowPose
    let occlusions: [CGRect]
    let isAccessibilitySize: Bool

    /// `allocation` is in the window reader's space.
    func playerGeometry(allocation: CGRect) -> NowPlayingCardGeometry {
        NowPlayingCardGeometry(
            allocation: allocation,
            windowSize: windowSize,
            safeAreaInsets: safeAreaInsets,
            isAccessibilitySize: isAccessibilitySize,
            pose: pose,
            occlusions: occlusions
        )
    }

    /// `allocation` is in the window reader's space.
    func paneGeometry(allocation: CGRect) -> NowPlayingPaneGeometry {
        NowPlayingPaneGeometry(
            allocation: allocation,
            windowSize: windowSize,
            safeAreaInsets: safeAreaInsets,
            pose: pose,
            occlusions: occlusions
        )
    }
}

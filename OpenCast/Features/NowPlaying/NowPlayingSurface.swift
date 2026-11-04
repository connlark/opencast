import SwiftUI

/// What the Now Playing overlay read from its window on this layout, so a
/// part of a window-sized surface can place itself from its own allocation.
nonisolated struct NowPlayingSurface: Equatable {
    let windowSize: CGSize
    let safeAreaInsets: EdgeInsets
    let pose: WindowPose
    let occlusions: [CGRect]
    let isAccessibilitySize: Bool

    /// The player in `allocation` (the window reader's space).
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

    /// The secondary pane in `allocation` (the window reader's space).
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

import SwiftUI

/// `allocation` is in the window reader's space and the insets are pane-local; x is
/// leading-relative.
nonisolated struct NowPlayingPaneGeometry: Equatable {
    let allocation: CGRect
    let contentInsets: EdgeInsets

    init(
        allocation: CGRect,
        windowSize: CGSize,
        safeAreaInsets: EdgeInsets,
        pose: WindowPose,
        occlusions: [CGRect]
    ) {
        let safe = CGRect(
            x: safeAreaInsets.leading,
            y: safeAreaInsets.top,
            width: max(0, windowSize.width - safeAreaInsets.leading - safeAreaInsets.trailing),
            height: max(0, windowSize.height - safeAreaInsets.top - safeAreaInsets.bottom)
        )
        var leading = max(0, safe.minX - allocation.minX)
        let trailing = max(0, allocation.maxX - safe.maxX)
        var top = max(0, safe.minY - allocation.minY)
        var bottom = max(0, allocation.maxY - safe.maxY)

        if case .foldedVertical(let band) = pose,
           NowPlayingCardGeometry.overlaps(allocation.minX...allocation.maxX, band.minX...band.maxX) {
            leading = max(leading, band.maxX - allocation.minX)
        }

        let columnStart = allocation.minX + leading
        let columnEnd = max(columnStart, allocation.maxX - trailing)
        for region in occlusions
        where NowPlayingCardGeometry.overlaps(region.minX...region.maxX, columnStart...columnEnd)
            && NowPlayingCardGeometry.overlaps(region.minY...region.maxY, allocation.minY...allocation.maxY) {
            if region.midY < allocation.midY {
                top = max(top, region.maxY - allocation.minY)
            } else {
                bottom = max(bottom, allocation.maxY - region.minY)
            }
        }

        self.allocation = allocation
        contentInsets = EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing)
    }

    /// The pane's content in the window reader's space.
    var contentFrame: CGRect {
        CGRect(
            x: allocation.minX + contentInsets.leading,
            y: allocation.minY + contentInsets.top,
            width: max(0, allocation.width - contentInsets.leading - contentInsets.trailing),
            height: max(0, allocation.height - contentInsets.top - contentInsets.bottom)
        )
    }
}
